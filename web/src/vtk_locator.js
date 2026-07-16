import '@kitware/vtk.js/Rendering/Profiles/Geometry';

import vtkActor from '@kitware/vtk.js/Rendering/Core/Actor';
import vtkBFSConnectivityFilter from '@kitware/vtk.js/Filters/General/BFSConnectivityFilter';
import vtkDataArray from '@kitware/vtk.js/Common/Core/DataArray';
import vtkGenericRenderWindow from '@kitware/vtk.js/Rendering/Misc/GenericRenderWindow';
import vtkImageData from '@kitware/vtk.js/Common/DataModel/ImageData';
import vtkImageMarchingCubes from '@kitware/vtk.js/Filters/General/ImageMarchingCubes';
import vtkMapper from '@kitware/vtk.js/Rendering/Core/Mapper';
import vtkPolyDataNormals from '@kitware/vtk.js/Filters/Core/PolyDataNormals';
import vtkWindowedSincPolyDataFilter from '@kitware/vtk.js/Filters/General/WindowedSincPolyDataFilter';

const maximumDecodedBytes = 2 * 1024 * 1024;
const captureTimeoutMilliseconds = 15_000;
let retainedLocator;

const now = () => performance.now();

const finitePositiveInteger = (value) =>
  Number.isInteger(value) && value > 0;

const derivePatientGeometry = (indexToPatient) => {
  if (
    indexToPatient.length !== 16 ||
    Array.from(indexToPatient).some((value) => !Number.isFinite(value))
  ) {
    throw new Error('indexToPatient must be a finite 4x4 matrix');
  }
  const spacing = [0, 1, 2].map((column) =>
    Math.hypot(
      indexToPatient[column],
      indexToPatient[4 + column],
      indexToPatient[8 + column],
    ),
  );
  if (spacing.some((value) => value <= 0)) {
    throw new Error('indexToPatient must have positive axis spacing');
  }
  const direction = Array.from({ length: 9 }, (_, index) => {
    const row = Math.floor(index / 3);
    const column = index % 3;
    return indexToPatient[row * 4 + column] / spacing[column];
  });
  const [a, b, c, d, e, f, g, h, i] = direction;
  const determinant =
    a * (e * i - f * h) -
    b * (d * i - f * g) +
    c * (d * h - e * g);
  if (!Number.isFinite(determinant) || Math.abs(determinant) < 1e-9) {
    throw new Error('indexToPatient must have independent voxel axes');
  }
  const origin = [indexToPatient[3], indexToPatient[7], indexToPatient[11]];
  return { spacing, direction, origin };
};

const patientPoint = ({ direction, origin }, x, y, z) => [
  origin[0] + direction[0] * x + direction[1] * y + direction[2] * z,
  origin[1] + direction[3] * x + direction[4] * y + direction[5] * z,
  origin[2] + direction[6] * x + direction[7] * y + direction[8] * z,
];

const applyPatientGeometry = (mesh, geometry) => {
  const points = mesh.getPoints();
  const values = points.getData();
  for (let index = 0; index < values.length; index += 3) {
    const transformed = patientPoint(
      geometry,
      values[index],
      values[index + 1],
      values[index + 2],
    );
    values[index] = transformed[0];
    values[index + 1] = transformed[1];
    values[index + 2] = transformed[2];
  }
  points.setData(values, 3);
  mesh.modified();
};

const volumePatientCorners = (geometry, width, height, depth) => {
  const maximum = [
    (width - 1) * geometry.spacing[0],
    (height - 1) * geometry.spacing[1],
    (depth - 1) * geometry.spacing[2],
  ];
  const corners = [];
  for (const z of [0, maximum[2]]) {
    for (const y of [0, maximum[1]]) {
      for (const x of [0, maximum[0]]) {
        corners.push(patientPoint(geometry, x, y, z));
      }
    }
  }
  return corners;
};

const boundsFromPoints = (points) => {
  const bounds = [
    Number.POSITIVE_INFINITY,
    Number.NEGATIVE_INFINITY,
    Number.POSITIVE_INFINITY,
    Number.NEGATIVE_INFINITY,
    Number.POSITIVE_INFINITY,
    Number.NEGATIVE_INFINITY,
  ];
  for (const point of points) {
    bounds[0] = Math.min(bounds[0], point[0]);
    bounds[1] = Math.max(bounds[1], point[0]);
    bounds[2] = Math.min(bounds[2], point[1]);
    bounds[3] = Math.max(bounds[3], point[1]);
    bounds[4] = Math.min(bounds[4], point[2]);
    bounds[5] = Math.max(bounds[5], point[2]);
  }
  return bounds;
};

const projectPatientPoint = (matrix, point) => {
  const clipX =
    matrix[0] * point[0] +
    matrix[1] * point[1] +
    matrix[2] * point[2] +
    matrix[3];
  const clipY =
    matrix[4] * point[0] +
    matrix[5] * point[1] +
    matrix[6] * point[2] +
    matrix[7];
  const clipW =
    matrix[12] * point[0] +
    matrix[13] * point[1] +
    matrix[14] * point[2] +
    matrix[15];
  if (!Number.isFinite(clipW) || Math.abs(clipW) < 1e-12) {
    throw new Error('camera projection produced an invalid clip coordinate');
  }
  return [clipX / clipW, clipY / clipW];
};

const inspectAlpha = async (dataUrl) => {
  const blob = await (await fetch(dataUrl)).blob();
  const bitmap = await createImageBitmap(blob);
  try {
    const canvas = document.createElement('canvas');
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    const context = canvas.getContext('2d', { willReadFrequently: true });
    context.drawImage(bitmap, 0, 0);
    const values = context.getImageData(0, 0, bitmap.width, bitmap.height).data;
    let transparentPixels = 0;
    let opaquePixels = 0;
    for (let index = 3; index < values.length; index += 4) {
      if (values[index] === 0) transparentPixels += 1;
      if (values[index] === 255) opaquePixels += 1;
    }
    return {
      width: bitmap.width,
      height: bitmap.height,
      transparentPixels,
      opaquePixels,
    };
  } finally {
    bitmap.close();
  }
};

const createContainer = (width, height) => {
  const container = document.createElement('div');
  Object.assign(container.style, {
    position: 'fixed',
    left: '-10000px',
    top: '0',
    width: `${width}px`,
    height: `${height}px`,
    pointerEvents: 'none',
  });
  document.body.append(container);
  return container;
};

const nextPaint = () =>
  new Promise((resolve) =>
    requestAnimationFrame(() => requestAnimationFrame(resolve)),
  );

const captureWithContextGuard = async (canvas, capture) => {
  let timeout;
  let contextLossHandler;
  const failure = new Promise((_, reject) => {
    timeout = setTimeout(
      () => reject(new Error('vtk.js locator capture timed out')),
      captureTimeoutMilliseconds,
    );
    contextLossHandler = (event) => {
      event.preventDefault();
      reject(new Error('vtk.js locator WebGL context was lost'));
    };
    canvas.addEventListener('webglcontextlost', contextLossHandler, {
      once: true,
    });
  });
  try {
    return await Promise.race([capture(), failure]);
  } finally {
    clearTimeout(timeout);
    canvas.removeEventListener('webglcontextlost', contextLossHandler);
  }
};

const validateOptions = (options) => {
  const { bytes, width, height, depth, outputWidth, outputHeight } = options;
  if (!(bytes instanceof Uint8Array)) {
    throw new Error('bytes must be a Uint8Array');
  }
  if (
    !finitePositiveInteger(width) ||
    !finitePositiveInteger(height) ||
    !finitePositiveInteger(depth) ||
    !finitePositiveInteger(outputWidth) ||
    !finitePositiveInteger(outputHeight)
  ) {
    throw new Error('volume and output dimensions must be positive integers');
  }
  const expectedBytes = width * height * depth * 2;
  if (bytes.byteLength !== expectedBytes || expectedBytes > maximumDecodedBytes) {
    throw new Error('voxel bytes do not match the bounded volume dimensions');
  }
  const littleEndian = new Uint8Array(new Uint16Array([1]).buffer)[0] === 1;
  if (!littleEndian || bytes.byteOffset % 2 !== 0) {
    throw new Error('the zero-copy signed-int16 view is not supported');
  }
  validateCameraOptions(options);
};

const validateCameraOptions = (options) => {
  const {
    outputWidth,
    outputHeight,
    cameraAzimuthDegrees,
    cameraElevationDegrees,
    cameraZoom,
  } = options;
  if (
    !finitePositiveInteger(outputWidth) ||
    !finitePositiveInteger(outputHeight) ||
    !Number.isFinite(cameraAzimuthDegrees) ||
    !Number.isFinite(cameraElevationDegrees) ||
    cameraElevationDegrees < -89 ||
    cameraElevationDegrees > 89 ||
    !Number.isFinite(cameraZoom) ||
    cameraZoom < 0.5 ||
    cameraZoom > 5
  ) {
    throw new Error('camera and output dimensions are invalid');
  }
};

const applyCamera = ({
  camera,
  renderer,
  center,
  patientBounds,
  cameraAzimuthDegrees,
  cameraElevationDegrees,
  cameraZoom,
}) => {
  const azimuth = (cameraAzimuthDegrees * Math.PI) / 180;
  const elevation = (cameraElevationDegrees * Math.PI) / 180;
  const horizontal = Math.cos(elevation);
  camera.setFocalPoint(...center);
  camera.setPosition(
    center[0] + Math.sin(azimuth) * horizontal,
    center[1] + Math.sin(elevation),
    center[2] + Math.cos(azimuth) * horizontal,
  );
  camera.setViewUp(0, 1, 0);
  camera.setParallelProjection(true);
  renderer.resetCamera(patientBounds);
  camera.zoom(cameraZoom);
  renderer.resetCameraClippingRange();
};

const deleteLocator = (locator) => {
  if (!locator) return;
  locator.actor?.delete();
  locator.mapper?.delete();
  locator.normals?.delete();
  locator.smoothing?.delete();
  locator.connectivity?.delete();
  locator.marchingCubes?.delete();
  locator.image?.delete();
  locator.genericRenderWindow?.delete();
  locator.container?.remove();
};

export const disposeLocator = () => {
  deleteLocator(retainedLocator);
  retainedLocator = undefined;
};

export const initializeLocator = async (options) => {
  validateOptions(options);
  disposeLocator();
  const {
    bytes,
    width,
    height,
    depth,
    indexToPatient,
    outputWidth,
    outputHeight,
    cameraAzimuthDegrees,
    cameraElevationDegrees,
    cameraZoom,
  } = options;
  const totalStart = now();
  const geometry = derivePatientGeometry(indexToPatient);
  const patientCorners = volumePatientCorners(
    geometry,
    width,
    height,
    depth,
  );
  const patientBounds = boundsFromPoints(patientCorners);
  const voxels = new Int16Array(
    bytes.buffer,
    bytes.byteOffset,
    bytes.byteLength / 2,
  );
  const image = vtkImageData.newInstance();
  let marchingCubes;
  let connectivity;
  let smoothing;
  let normals;
  let mapper;
  let actor;
  let genericRenderWindow;
  let container;
  let didRetain = false;
  try {
    image.setDimensions(width, height, depth);
    // ImageMarchingCubes does not apply ImageData.direction. Extract and
    // smooth in axis-aligned physical space, then transform the mesh once.
    image.setSpacing(...geometry.spacing);
    image.setOrigin(0, 0, 0);
    image.getPointData().setScalars(
      vtkDataArray.newInstance({
        name: 'HU',
        numberOfComponents: 1,
        values: voxels,
      }),
    );

    const mainThreadProbeStart = now();
    const mainThreadProbe = new Promise((resolve) => {
      setTimeout(
        () => resolve(Math.max(1, Math.round((now() - mainThreadProbeStart) * 1000))),
        0,
      );
    });
    const extractionStart = now();
    marchingCubes = vtkImageMarchingCubes.newInstance({
      contourValue: -300,
      computeNormals: true,
      mergePoints: true,
    });
    marchingCubes.setInputData(image);
    marchingCubes.update();

    connectivity = vtkBFSConnectivityFilter.newInstance();
    connectivity.setInputData(marchingCubes.getOutputData());
    connectivity.setExtractionModeToLargest();
    connectivity.update();

    smoothing = vtkWindowedSincPolyDataFilter.newInstance({
      numberOfIterations: 10,
      passBand: 0.08,
      boundarySmoothing: false,
      featureEdgeSmoothing: false,
      nonManifoldSmoothing: true,
      normalizeCoordinates: true,
    });
    smoothing.setInputData(connectivity.getOutputData());
    smoothing.update();
    const transformedMesh = smoothing.getOutputData();
    applyPatientGeometry(transformedMesh, geometry);
    normals = vtkPolyDataNormals.newInstance({
      computePointNormals: true,
      computeCellNormals: false,
    });
    normals.setInputData(transformedMesh);
    normals.update();
    const mesh = normals.getOutputData();
    const extractionMicroseconds = Math.round((now() - extractionStart) * 1000);

    const meshPoints = mesh.getPoints().getNumberOfPoints();
    const meshTriangles = mesh.getPolys().getNumberOfCells();
    if (meshPoints <= 0 || meshTriangles <= 0) {
      throw new Error('surface extraction produced no geometry');
    }

    container = createContainer(outputWidth, outputHeight);
    genericRenderWindow = vtkGenericRenderWindow.newInstance({
      background: [0, 0, 0],
    });
    genericRenderWindow.setContainer(container);
    const renderer = genericRenderWindow.getRenderer();
    renderer.setBackground(0, 0, 0, 0);
    const renderWindow = genericRenderWindow.getRenderWindow();
    const openGLRenderWindow = genericRenderWindow.getApiSpecificRenderWindow();
    openGLRenderWindow.setSize(outputWidth, outputHeight);

    mapper = vtkMapper.newInstance();
    mapper.setInputData(mesh);
    mapper.setScalarVisibility(false);
    actor = vtkActor.newInstance();
    actor.setMapper(mapper);
    const property = actor.getProperty();
    property.setColor(0.78, 0.8, 0.8);
    property.setAmbient(0.42);
    property.setDiffuse(0.82);
    property.setSpecular(0.18);
    property.setSpecularPower(18);
    property.setInterpolationToPhong();
    renderer.addActor(actor);

    const center = [
      (patientBounds[0] + patientBounds[1]) * 0.5,
      (patientBounds[2] + patientBounds[3]) * 0.5,
      (patientBounds[4] + patientBounds[5]) * 0.5,
    ];
    const camera = renderer.getActiveCamera();
    applyCamera({
      camera,
      renderer,
      center,
      patientBounds,
      cameraAzimuthDegrees,
      cameraElevationDegrees,
      cameraZoom,
    });

    renderWindow.render();
    await nextPaint();
    const mainThreadBlockMicroseconds = await mainThreadProbe;
    const captureStart = now();
    const { pngDataUrl, alpha } = await captureWithContextGuard(
      openGLRenderWindow.getCanvas(),
      async () => {
        const capture = openGLRenderWindow.captureNextImage('image/png');
        renderWindow.render();
        const pngDataUrl = await capture;
        return { pngDataUrl, alpha: await inspectAlpha(pngDataUrl) };
      },
    );
    const captureMicroseconds = Math.round((now() - captureStart) * 1000);
    if (alpha.width !== outputWidth || alpha.height !== outputHeight) {
      throw new Error('captured frame dimensions do not match the request');
    }
    const patientToClip = Array.from(
      camera.getCompositeProjectionMatrix(outputWidth / outputHeight, -1, 1),
    );
    const projectedVolumeCorners = patientCorners.flatMap((point) =>
      projectPatientPoint(patientToClip, point),
    );
    const focalClipX =
      patientToClip[0] * center[0] +
      patientToClip[1] * center[1] +
      patientToClip[2] * center[2] +
      patientToClip[3];
    const focalClipY =
      patientToClip[4] * center[0] +
      patientToClip[5] * center[1] +
      patientToClip[6] * center[2] +
      patientToClip[7];
    const focalClipW =
      patientToClip[12] * center[0] +
      patientToClip[13] * center[1] +
      patientToClip[14] * center[2] +
      patientToClip[15];
    if (
      Math.abs(focalClipX / focalClipW) > 1e-6 ||
      Math.abs(focalClipY / focalClipW) > 1e-6
    ) {
      throw new Error('camera projection matrix is not row-major patient-to-clip');
    }

    retainedLocator = {
      actor,
      mapper,
      normals,
      smoothing,
      connectivity,
      marchingCubes,
      image,
      genericRenderWindow,
      container,
      renderer,
      renderWindow,
      openGLRenderWindow,
      camera,
      center,
      patientBounds,
      patientCorners,
      meshPoints,
      meshTriangles,
    };
    didRetain = true;
    return {
      pngDataUrl,
      width: alpha.width,
      height: alpha.height,
      patientToClip,
      renderMicroseconds: Math.round((now() - totalStart) * 1000),
      extractionMicroseconds,
      captureMicroseconds,
      mainThreadBlockMicroseconds,
      meshPoints,
      meshTriangles,
      transparentPixels: alpha.transparentPixels,
      opaquePixels: alpha.opaquePixels,
      patientBounds,
      projectedVolumeCorners,
    };
  } finally {
    if (!didRetain) {
      deleteLocator({
        actor,
        mapper,
        normals,
        smoothing,
        connectivity,
        marchingCubes,
        image,
        genericRenderWindow,
        container,
      });
    }
  }
};

export const renderLocatorCamera = async (options) => {
  validateCameraOptions(options);
  const locator = retainedLocator;
  if (!locator) {
    throw new Error('initialize the vtk.js locator before updating its camera');
  }
  const {
    outputWidth,
    outputHeight,
    cameraAzimuthDegrees,
    cameraElevationDegrees,
    cameraZoom,
  } = options;
  const totalStart = now();
  locator.openGLRenderWindow.setSize(outputWidth, outputHeight);
  applyCamera({
    camera: locator.camera,
    renderer: locator.renderer,
    center: locator.center,
    patientBounds: locator.patientBounds,
    cameraAzimuthDegrees,
    cameraElevationDegrees,
    cameraZoom,
  });
  const mainThreadProbeStart = now();
  const mainThreadProbe = new Promise((resolve) => {
    setTimeout(
      () => resolve(Math.max(1, Math.round((now() - mainThreadProbeStart) * 1000))),
      0,
    );
  });
  locator.renderWindow.render();
  await nextPaint();
  const mainThreadBlockMicroseconds = await mainThreadProbe;
  const captureStart = now();
  const { pngDataUrl, alpha } = await captureWithContextGuard(
    locator.openGLRenderWindow.getCanvas(),
    async () => {
      const capture = locator.openGLRenderWindow.captureNextImage('image/png');
      locator.renderWindow.render();
      const pngDataUrl = await capture;
      return { pngDataUrl, alpha: await inspectAlpha(pngDataUrl) };
    },
  );
  const captureMicroseconds = Math.round((now() - captureStart) * 1000);
  const patientToClip = Array.from(
    locator.camera.getCompositeProjectionMatrix(outputWidth / outputHeight, -1, 1),
  );
  const projectedVolumeCorners = locator.patientCorners.flatMap((point) =>
    projectPatientPoint(patientToClip, point),
  );
  return {
    pngDataUrl,
    width: alpha.width,
    height: alpha.height,
    patientToClip,
    renderMicroseconds: Math.round((now() - totalStart) * 1000),
    extractionMicroseconds: 0,
    captureMicroseconds,
    mainThreadBlockMicroseconds,
    meshPoints: locator.meshPoints,
    meshTriangles: locator.meshTriangles,
    transparentPixels: alpha.transparentPixels,
    opaquePixels: alpha.opaquePixels,
    patientBounds: locator.patientBounds,
    projectedVolumeCorners,
  };
};
