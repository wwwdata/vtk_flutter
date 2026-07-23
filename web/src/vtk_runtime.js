import '@kitware/vtk.js/Rendering/Profiles/Geometry.js';
import '@kitware/vtk.js/Rendering/Profiles/Volume.js';

import vtkActor from '@kitware/vtk.js/Rendering/Core/Actor.js';
import vtkBFSConnectivityFilter from '@kitware/vtk.js/Filters/General/BFSConnectivityFilter.js';
import vtkCamera from '@kitware/vtk.js/Rendering/Core/Camera.js';
import vtkColorTransferFunction from '@kitware/vtk.js/Rendering/Core/ColorTransferFunction.js';
import vtkDataArray from '@kitware/vtk.js/Common/Core/DataArray.js';
import vtkGenericRenderWindow from '@kitware/vtk.js/Rendering/Misc/GenericRenderWindow.js';
import vtkImageData from '@kitware/vtk.js/Common/DataModel/ImageData.js';
import vtkImageMarchingCubes from '@kitware/vtk.js/Filters/General/ImageMarchingCubes.js';
import vtkImageMapper from '@kitware/vtk.js/Rendering/Core/ImageMapper.js';
import vtkImageProperty from '@kitware/vtk.js/Rendering/Core/ImageProperty.js';
import vtkImageReslice from '@kitware/vtk.js/Imaging/Core/ImageReslice.js';
import vtkImageSlice from '@kitware/vtk.js/Rendering/Core/ImageSlice.js';
import vtkMapper from '@kitware/vtk.js/Rendering/Core/Mapper.js';
import vtkPiecewiseFunction from '@kitware/vtk.js/Common/DataModel/PiecewiseFunction.js';
import vtkProperty from '@kitware/vtk.js/Rendering/Core/Property.js';
import vtkRenderer from '@kitware/vtk.js/Rendering/Core/Renderer.js';
import vtkVolume from '@kitware/vtk.js/Rendering/Core/Volume.js';
import vtkVolumeMapper from '@kitware/vtk.js/Rendering/Core/VolumeMapper.js';
import vtkVolumeProperty from '@kitware/vtk.js/Rendering/Core/VolumeProperty.js';
import vtkWindowedSincPolyDataFilter from '@kitware/vtk.js/Filters/General/WindowedSincPolyDataFilter.js';

const maximumImageBytes = 256 * 1024 * 1024;
const maximumRenderLayers = 64;
const captureTimeoutMilliseconds = 15_000;

const transformMarchingCubesOutput = (input, output) => {
  const origin = input.getOrigin();
  const spacing = input.getSpacing();
  const points = output.getPoints();
  const coordinates = points.getData();
  const index = [0, 0, 0];
  const world = [0, 0, 0];
  for (let offset = 0; offset < coordinates.length; offset += 3) {
    for (let axis = 0; axis < 3; axis++) {
      index[axis] = (coordinates[offset + axis] - origin[axis]) / spacing[axis];
    }
    input.indexToWorld(index, world);
    coordinates.set(world, offset);
  }
  points.modified();

  const normals = output.getPointData().getNormals();
  if (!normals) return;
  const direction = input.getDirection();
  const vectors = normals.getData();
  for (let offset = 0; offset < vectors.length; offset += 3) {
    const x = vectors[offset];
    const y = vectors[offset + 1];
    const z = vectors[offset + 2];
    const transformed = [
      direction[0] * x + direction[3] * y + direction[6] * z,
      direction[1] * x + direction[4] * y + direction[7] * z,
      direction[2] * x + direction[5] * y + direction[8] * z,
    ];
    const length = Math.hypot(...transformed);
    if (length > 0) {
      vectors[offset] = transformed[0] / length;
      vectors[offset + 1] = transformed[1] / length;
      vectors[offset + 2] = transformed[2] / length;
    }
  }
  normals.modified();
};

export const createFlyingEdges3D = () => {
  const contour = {};
  const model = {};
  vtkImageMarchingCubes.extend(contour, model, { mergePoints: true });
  const requestData = contour.requestData;
  contour.requestData = (inData, outData) => {
    requestData(inData, outData);
    if (inData[0] && outData[0]) {
      transformMarchingCubesOutput(inData[0], outData[0]);
    }
  };
  return Object.freeze(contour);
};

const supportedObjectTypes = Object.freeze([
  'imageData',
  'imageReslice',
  'imageActor',
  'imageSliceMapper',
  'imageProperty',
  'smartVolumeMapper',
  'colorTransferFunction',
  'piecewiseFunction',
  'volumeProperty',
  'volume',
  'flyingEdges3D',
  'polyDataConnectivityFilter',
  'windowedSincPolyDataFilter',
  'polyDataMapper',
  'actor',
  'property',
  'renderer',
  'camera',
  'algorithmOutput',
]);

const supportedScalarTypes = Object.freeze([
  'uint8',
  'int8',
  'uint16',
  'int16',
  'uint32',
  'int32',
  'float32',
  'float64',
]);

const limitations = Object.freeze({
  flyingEdges3D:
    'vtk.js has no FlyingEdges implementation; ImageMarchingCubes is used and only contour index 0 is supported.',
  smartVolumeMapper:
    'vtk.js VolumeMapper is used; native SmartVolumeMapper backend selection is unavailable.',
  imageMapToWindowLevelColors:
    'vtk.js 36 has no ImageMapToWindowLevelColors implementation.',
  polyDataConnectivityFilter:
    'vtk.js BFSConnectivityFilter cannot implement closest-point extraction or region coloring.',
  imagePropertyCubicInterpolation:
    'vtk.js ImageProperty supports nearest and linear interpolation only.',
  volumePropertyCubicInterpolation:
    'vtk.js VolumeProperty supports nearest and linear interpolation only.',
  volumeIsoSurfaceBlend:
    'vtk.js VolumeMapper has no blend mode equivalent to native iso-surface blending.',
  presentation:
    'Frames are rendered offscreen and returned as PNG bytes for Flutter Image presentation; external textures are unavailable on web.',
});

const objectFactories = Object.freeze({
  imageReslice: () => vtkImageReslice.newInstance(),
  imageActor: () => vtkImageSlice.newInstance(),
  imageSliceMapper: () => vtkImageMapper.newInstance(),
  imageProperty: () => vtkImageProperty.newInstance(),
  smartVolumeMapper: () => vtkVolumeMapper.newInstance(),
  colorTransferFunction: () => vtkColorTransferFunction.newInstance(),
  piecewiseFunction: () => vtkPiecewiseFunction.newInstance(),
  volumeProperty: () => vtkVolumeProperty.newInstance(),
  volume: () => vtkVolume.newInstance(),
  flyingEdges3D: createFlyingEdges3D,
  polyDataConnectivityFilter: () => vtkBFSConnectivityFilter.newInstance(),
  windowedSincPolyDataFilter: () =>
    vtkWindowedSincPolyDataFilter.newInstance(),
  polyDataMapper: () => vtkMapper.newInstance(),
  actor: () => vtkActor.newInstance(),
  property: () => vtkProperty.newInstance(),
  renderer: () => vtkRenderer.newInstance(),
  camera: () => vtkCamera.newInstance(),
});

const inputTargets = Object.freeze([
  'imageReslice',
  'imageSliceMapper',
  'smartVolumeMapper',
  'flyingEdges3D',
  'polyDataConnectivityFilter',
  'windowedSincPolyDataFilter',
  'polyDataMapper',
]);

const algorithmTargets = Object.freeze([
  'imageReslice',
  'flyingEdges3D',
  'polyDataConnectivityFilter',
  'windowedSincPolyDataFilter',
]);

const operationTargetTypes = Object.freeze({
  setInputData: inputTargets,
  setInputConnection: inputTargets,
  getOutputPort: algorithmTargets,
  setResliceAxes: ['imageReslice'],
  setOutputDimensionality: ['imageReslice'],
  setResliceInterpolation: ['imageReslice'],
  setAutoCropOutput: ['imageReslice'],
  setWindow: [],
  setLevel: [],
  setMapper: ['imageActor', 'volume', 'actor'],
  setProperty: ['imageActor', 'volume', 'actor'],
  setImageInterpolation: ['imageProperty'],
  setColorWindow: ['imageProperty'],
  setColorLevel: ['imageProperty'],
  setVolumeBlendMode: ['smartVolumeMapper'],
  setSampleDistance: ['smartVolumeMapper'],
  addRgbPoint: ['colorTransferFunction'],
  removeAllPoints: ['colorTransferFunction', 'piecewiseFunction'],
  addOpacityPoint: ['piecewiseFunction'],
  setColorTransferFunction: ['volumeProperty'],
  setScalarOpacity: ['volumeProperty'],
  setVolumeInterpolation: ['volumeProperty'],
  setShade: ['volumeProperty'],
  setAmbient: ['volumeProperty', 'property'],
  setDiffuse: ['volumeProperty', 'property'],
  setSpecular: ['volumeProperty', 'property'],
  setSpecularPower: ['volumeProperty', 'property'],
  setScalarOpacityUnitDistance: ['volumeProperty'],
  setIsoValue: ['flyingEdges3D'],
  setComputeNormals: ['flyingEdges3D'],
  setConnectivityMode: ['polyDataConnectivityFilter'],
  setClosestPoint: [],
  setColorRegions: [],
  setNumberOfIterations: ['windowedSincPolyDataFilter'],
  setPassBand: ['windowedSincPolyDataFilter'],
  setBoundarySmoothing: ['windowedSincPolyDataFilter'],
  setFeatureEdgeSmoothing: ['windowedSincPolyDataFilter'],
  setNormalizeCoordinates: ['windowedSincPolyDataFilter'],
  setScalarVisibility: ['polyDataMapper'],
  setColor: ['property'],
  setOpacity: ['property'],
  setRepresentation: ['property'],
  setLineWidth: ['property'],
  addActor: ['renderer'],
  removeActor: ['renderer'],
  addVolume: ['renderer'],
  removeVolume: ['renderer'],
  setBackground: ['renderer'],
  setActiveCamera: ['renderer'],
  resetCamera: ['renderer'],
  setPosition: ['actor', 'camera'],
  setFocalPoint: ['camera'],
  setViewUp: ['camera'],
  setParallelProjection: ['camera'],
  setParallelScale: ['camera'],
  setClippingRange: ['camera'],
  azimuth: ['camera'],
  elevation: ['camera'],
  roll: ['camera'],
  zoom: ['camera'],
  dolly: ['camera'],
});

const sessions = new Map();
let nextSessionId = 1;
let nextObjectHandle = 1;

const now = () =>
  typeof performance === 'undefined' ? Date.now() : performance.now();

const fail = (message) => {
  throw new Error(`vtk_flutter web protocol: ${message}`);
};

const expectPositiveInteger = (value, name) => {
  if (!Number.isSafeInteger(value) || value <= 0) {
    fail(`${name} must be a positive safe integer`);
  }
  return value;
};

const expectNonNegativeInteger = (value, name) => {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(`${name} must be a non-negative safe integer`);
  }
  return value;
};

const expectFiniteNumber = (value, name) => {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    fail(`${name} must be finite`);
  }
  return value;
};

const expectUnitInterval = (value, name) => {
  const number = expectFiniteNumber(value, name);
  if (number < 0 || number > 1) fail(`${name} must be between 0 and 1`);
  return number;
};

const expectBoolean = (value, name) => {
  if (typeof value !== 'boolean') fail(`${name} must be a boolean`);
  return value;
};

const expectString = (value, name) => {
  if (typeof value !== 'string') fail(`${name} must be a string`);
  return value;
};

const expectArray = (value, length, name) => {
  if (
    (!Array.isArray(value) && !ArrayBuffer.isView(value)) ||
    value.length !== length
  ) {
    fail(`${name} must contain exactly ${length} values`);
  }
  return Array.from(value, (entry, index) =>
    expectFiniteNumber(entry, `${name}[${index}]`),
  );
};

const expectArguments = (args, count, operation) => {
  if (!Array.isArray(args) || args.length !== count) {
    fail(`${operation} expects exactly ${count} arguments`);
  }
  return args;
};

const sessionFor = (sessionId) => {
  expectPositiveInteger(sessionId, 'sessionId');
  const session = sessions.get(sessionId);
  if (!session) fail(`unknown session ${sessionId}`);
  return session;
};

const objectFor = (session, handle, expectedTypes, name = 'object') => {
  expectPositiveInteger(handle, `${name} handle`);
  const record = session.objects.get(handle);
  if (!record) fail(`unknown ${name} handle ${handle}`);
  if (expectedTypes && !expectedTypes.includes(record.type)) {
    fail(
      `${name} handle ${handle} is ${record.type}; expected ${expectedTypes.join(
        ' or ',
      )}`,
    );
  }
  return record;
};

const addObject = (session, type, instance, owned = true) => {
  const handle = nextObjectHandle++;
  session.objects.set(handle, { type, instance, owned });
  return handle;
};

const objectArgument = (session, args, index, expectedTypes, operation) =>
  objectFor(
    session,
    args[index],
    expectedTypes,
    `${operation} argument ${index}`,
  );

const scalarArrayConstructors = Object.freeze({
  uint8: Uint8Array,
  int8: Int8Array,
  uint16: Uint16Array,
  int16: Int16Array,
  uint32: Uint32Array,
  int32: Int32Array,
  float32: Float32Array,
  float64: Float64Array,
});

const validateImageInput = (input) => {
  if (!input || typeof input !== 'object') fail('image input is required');
  if (!(input.bytes instanceof Uint8Array)) {
    fail('image bytes must be a Uint8Array');
  }
  const scalarType = expectString(input.scalarType, 'scalarType');
  const ScalarArray = scalarArrayConstructors[scalarType];
  if (!ScalarArray) fail(`unsupported scalar type ${scalarType}`);
  const dimensions = expectArray(input.dimensions, 3, 'dimensions');
  dimensions.forEach((value, index) =>
    expectPositiveInteger(value, `dimensions[${index}]`),
  );
  const componentCount = expectPositiveInteger(
    input.componentCount,
    'componentCount',
  );
  const origin = expectArray(input.origin, 3, 'origin');
  const spacing = expectArray(input.spacing, 3, 'spacing');
  if (spacing.some((value) => value <= 0)) {
    fail('spacing values must be positive');
  }
  const direction = expectArray(input.direction, 9, 'direction');
  const valueCount =
    dimensions[0] * dimensions[1] * dimensions[2] * componentCount;
  if (!Number.isSafeInteger(valueCount)) fail('image value count is too large');
  const expectedBytes = valueCount * ScalarArray.BYTES_PER_ELEMENT;
  if (
    input.bytes.byteLength !== expectedBytes ||
    expectedBytes > maximumImageBytes
  ) {
    fail(
      `image byte length ${input.bytes.byteLength} does not match ${expectedBytes}`,
    );
  }
  return {
    ScalarArray,
    componentCount,
    dimensions,
    direction,
    origin,
    spacing,
  };
};

export const createScalarImage = (input) => {
  const validated = validateImageInput(input);
  const bytes = new Uint8Array(input.bytes);
  const values = new validated.ScalarArray(
    bytes.buffer,
    bytes.byteOffset,
    bytes.byteLength / validated.ScalarArray.BYTES_PER_ELEMENT,
  );
  const image = vtkImageData.newInstance();
  image.setDimensions(...validated.dimensions);
  image.setOrigin(...validated.origin);
  image.setSpacing(...validated.spacing);
  image.setDirection(
    validated.direction[0],
    validated.direction[3],
    validated.direction[6],
    validated.direction[1],
    validated.direction[4],
    validated.direction[7],
    validated.direction[2],
    validated.direction[5],
    validated.direction[8],
  );
  image.getPointData().setScalars(
    vtkDataArray.newInstance({
      name: 'Scalars',
      numberOfComponents: validated.componentCount,
      values,
    }),
  );
  return image;
};

const canRender = () => {
  if (typeof document === 'undefined') return false;
  try {
    const canvas = document.createElement('canvas');
    const context =
      canvas.getContext('webgl2') ?? canvas.getContext('webgl');
    context?.getExtension('WEBGL_lose_context')?.loseContext();
    return context !== null;
  } catch {
    return false;
  }
};

const createContainer = () => {
  if (typeof document === 'undefined' || !document.body) {
    fail('rendering requires an attached document body');
  }
  const container = document.createElement('div');
  container.setAttribute('aria-hidden', 'true');
  Object.assign(container.style, {
    position: 'fixed',
    left: '-100000px',
    top: '0',
    width: '1px',
    height: '1px',
    overflow: 'hidden',
    pointerEvents: 'none',
  });
  document.body.append(container);
  return container;
};

const withCaptureGuard = async (canvas, capture) => {
  let timeout;
  let contextLossHandler;
  const failure = new Promise((_, reject) => {
    timeout = setTimeout(
      () => reject(new Error('vtk.js PNG capture timed out')),
      captureTimeoutMilliseconds,
    );
    contextLossHandler = (event) => {
      event.preventDefault();
      reject(new Error('vtk.js WebGL context was lost'));
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

export const createRenderTarget = ({
  container = createContainer(),
  genericRenderWindow = vtkGenericRenderWindow.newInstance({
    background: [0, 0, 0, 0],
    listenWindowResize: false,
  }),
} = {}) => {
  genericRenderWindow.setContainer(container);
  const renderWindow = genericRenderWindow.getRenderWindow();
  const defaultRenderer = genericRenderWindow.getRenderer();
  const apiSpecificRenderWindow =
    genericRenderWindow.getApiSpecificRenderWindow();
  const attachedRenderers = new Set([defaultRenderer]);

  const detach = (renderer) => {
    if (!attachedRenderers.delete(renderer)) return;
    renderWindow.removeRenderer(renderer);
  };

  const clear = (width, height) => {
    const context = apiSpecificRenderWindow.getContext();
    context.enable(context.SCISSOR_TEST);
    context.scissor(0, 0, width, height);
    context.viewport(0, 0, width, height);
    context.colorMask(true, true, true, true);
    context.depthMask(true);
    context.clearColor(0, 0, 0, 0);
    context.clearDepth(1);
    context.clear(context.COLOR_BUFFER_BIT | context.DEPTH_BUFFER_BIT);
  };

  return {
    detach,
    async renderLayout(layers, width, height, primaryLayer) {
      for (const renderer of [...attachedRenderers]) detach(renderer);
      container.style.width = `${width}px`;
      container.style.height = `${height}px`;
      apiSpecificRenderWindow.setSize(width, height);

      try {
        clear(width, height);
        for (const layer of layers) {
          layer.renderer.setViewport(...layer.viewport);
          renderWindow.addRenderer(layer.renderer);
          attachedRenderers.add(layer.renderer);
        }

        let renderMicroseconds = 0;
        const captureStart = now();
        const pngDataUrl = await withCaptureGuard(
          apiSpecificRenderWindow.getCanvas(),
          async () => {
            const capture = apiSpecificRenderWindow.captureNextImage('image/png');
            const renderStart = now();
            renderWindow.render();
            renderMicroseconds = Math.round((now() - renderStart) * 1000);
            return capture;
          },
        );
        const captureMicroseconds = Math.round((now() - captureStart) * 1000);
        const primary = layers[primaryLayer];
        const [left, bottom, right, top] = primary.viewport;
        const pixelAspect =
          (width * (right - left)) / (height * (top - bottom));
        const camera = primary.renderer.getActiveCamera();
        const worldToClip = Array.from(
          camera.getCompositeProjectionMatrix(pixelAspect, -1, 1),
        );
        if (
          worldToClip.length !== 16 ||
          worldToClip.some((value) => !Number.isFinite(value))
        ) {
          fail('renderer returned an invalid world-to-clip matrix');
        }
        return {
          pngDataUrl,
          width,
          height,
          renderMicroseconds,
          captureMicroseconds,
          worldToClip,
        };
      } finally {
        for (const renderer of [...attachedRenderers]) detach(renderer);
      }
    },
    dispose() {
      for (const renderer of [...attachedRenderers]) detach(renderer);
      genericRenderWindow.delete();
      container.remove();
    },
  };
};

const enumArgument = (args, operation, values) => {
  expectArguments(args, 1, operation);
  const value = expectString(args[0], `${operation} value`);
  if (!values.includes(value)) fail(`${operation} does not support ${value}`);
  return value;
};

const numericArguments = (args, count, operation) => {
  expectArguments(args, count, operation);
  return args.map((value, index) =>
    expectFiniteNumber(value, `${operation} argument ${index}`),
  );
};

const booleanArgument = (args, operation) => {
  expectArguments(args, 1, operation);
  return expectBoolean(args[0], `${operation} argument`);
};

const invokeOperation = (session, target, operation, args) => {
  switch (operation) {
    case 'setInputData': {
      expectArguments(args, 1, operation);
      const input = objectArgument(
        session,
        args,
        0,
        ['imageData'],
        operation,
      );
      target.instance.setInputData(input.instance);
      return null;
    }
    case 'setInputConnection': {
      expectArguments(args, 2, operation);
      const port = expectNonNegativeInteger(args[0], 'input port');
      const output = objectArgument(
        session,
        args,
        1,
        ['algorithmOutput'],
        operation,
      );
      target.instance.setInputConnection(output.instance, port);
      return null;
    }
    case 'getOutputPort': {
      expectArguments(args, 1, operation);
      const port = expectNonNegativeInteger(args[0], 'output port');
      return addObject(
        session,
        'algorithmOutput',
        target.instance.getOutputPort(port),
        false,
      );
    }
    case 'setResliceAxes': {
      expectArguments(args, 1, operation);
      target.instance.setResliceAxes(expectArray(args[0], 16, 'reslice axes'));
      return null;
    }
    case 'setOutputDimensionality': {
      expectArguments(args, 1, operation);
      const dimensions = expectNonNegativeInteger(
        args[0],
        'output dimensionality',
      );
      if (dimensions !== 2 && dimensions !== 3) {
        fail('output dimensionality must be 2 or 3');
      }
      target.instance.setOutputDimensionality(dimensions);
      return null;
    }
    case 'setResliceInterpolation': {
      const interpolation = enumArgument(args, operation, [
        'nearest',
        'linear',
        'cubic',
      ]);
      target.instance.setInterpolationMode(
        { nearest: 0, linear: 1, cubic: 2 }[interpolation],
      );
      return null;
    }
    case 'setAutoCropOutput':
      target.instance.setAutoCropOutput(booleanArgument(args, operation));
      return null;
    case 'setMapper': {
      expectArguments(args, 1, operation);
      const expected = {
        imageActor: ['imageSliceMapper'],
        volume: ['smartVolumeMapper'],
        actor: ['polyDataMapper'],
      }[target.type];
      target.instance.setMapper(
        objectArgument(session, args, 0, expected, operation).instance,
      );
      return null;
    }
    case 'setProperty': {
      expectArguments(args, 1, operation);
      const expected = {
        imageActor: ['imageProperty'],
        volume: ['volumeProperty'],
        actor: ['property'],
      }[target.type];
      target.instance.setProperty(
        objectArgument(session, args, 0, expected, operation).instance,
      );
      return null;
    }
    case 'setImageInterpolation': {
      const interpolation = enumArgument(args, operation, [
        'nearest',
        'linear',
      ]);
      target.instance.setInterpolationType(
        { nearest: 0, linear: 1 }[interpolation],
      );
      return null;
    }
    case 'setColorWindow':
      target.instance.setColorWindow(numericArguments(args, 1, operation)[0]);
      return null;
    case 'setColorLevel':
      target.instance.setColorLevel(numericArguments(args, 1, operation)[0]);
      return null;
    case 'setVolumeBlendMode': {
      const blendMode = enumArgument(args, operation, [
        'composite',
        'maximumIntensity',
        'minimumIntensity',
        'averageIntensity',
        'additive',
      ]);
      target.instance.setBlendMode(
        {
          composite: 0,
          maximumIntensity: 1,
          minimumIntensity: 2,
          averageIntensity: 3,
          additive: 4,
        }[blendMode],
      );
      return null;
    }
    case 'setSampleDistance':
      target.instance.setSampleDistance(
        numericArguments(args, 1, operation)[0],
      );
      return null;
    case 'addRgbPoint':
      target.instance.addRGBPoint(...numericArguments(args, 4, operation));
      return null;
    case 'removeAllPoints':
      expectArguments(args, 0, operation);
      target.instance.removeAllPoints();
      return null;
    case 'addOpacityPoint':
      target.instance.addPoint(...numericArguments(args, 2, operation));
      return null;
    case 'setColorTransferFunction': {
      expectArguments(args, 1, operation);
      const transferFunction = objectArgument(
        session,
        args,
        0,
        ['colorTransferFunction'],
        operation,
      );
      target.instance.setRGBTransferFunction(0, transferFunction.instance);
      return null;
    }
    case 'setScalarOpacity': {
      expectArguments(args, 1, operation);
      const opacityFunction = objectArgument(
        session,
        args,
        0,
        ['piecewiseFunction'],
        operation,
      );
      target.instance.setScalarOpacity(0, opacityFunction.instance);
      return null;
    }
    case 'setVolumeInterpolation': {
      const interpolation = enumArgument(args, operation, [
        'nearest',
        'linear',
      ]);
      target.instance.setInterpolationType(
        { nearest: 0, linear: 1 }[interpolation],
      );
      return null;
    }
    case 'setShade':
      target.instance.setShade(booleanArgument(args, operation));
      return null;
    case 'setAmbient':
      target.instance.setAmbient(numericArguments(args, 1, operation)[0]);
      return null;
    case 'setDiffuse':
      target.instance.setDiffuse(numericArguments(args, 1, operation)[0]);
      return null;
    case 'setSpecular':
      target.instance.setSpecular(numericArguments(args, 1, operation)[0]);
      return null;
    case 'setSpecularPower':
      target.instance.setSpecularPower(
        numericArguments(args, 1, operation)[0],
      );
      return null;
    case 'setScalarOpacityUnitDistance':
      target.instance.setScalarOpacityUnitDistance(
        0,
        numericArguments(args, 1, operation)[0],
      );
      return null;
    case 'setIsoValue': {
      expectArguments(args, 2, operation);
      const index = expectNonNegativeInteger(args[0], 'contour index');
      if (index !== 0) {
        fail('ImageMarchingCubes supports contour index 0 only');
      }
      target.instance.setContourValue(
        expectFiniteNumber(args[1], 'contour value'),
      );
      return null;
    }
    case 'setComputeNormals':
      target.instance.setComputeNormals(booleanArgument(args, operation));
      return null;
    case 'setConnectivityMode': {
      const mode = enumArgument(args, operation, [
        'allRegions',
        'largestRegion',
      ]);
      if (mode === 'allRegions') {
        target.instance.setExtractionModeToAll();
      } else {
        target.instance.setExtractionModeToLargest();
      }
      return null;
    }
    case 'setNumberOfIterations':
      target.instance.setNumberOfIterations(
        expectNonNegativeInteger(
          numericArguments(args, 1, operation)[0],
          'iteration count',
        ),
      );
      return null;
    case 'setPassBand':
      target.instance.setPassBand(numericArguments(args, 1, operation)[0]);
      return null;
    case 'setBoundarySmoothing':
      target.instance.setBoundarySmoothing(booleanArgument(args, operation));
      return null;
    case 'setFeatureEdgeSmoothing':
      target.instance.setFeatureEdgeSmoothing(
        booleanArgument(args, operation),
      );
      return null;
    case 'setNormalizeCoordinates':
      target.instance.setNormalizeCoordinates(booleanArgument(args, operation));
      return null;
    case 'setScalarVisibility':
      target.instance.setScalarVisibility(booleanArgument(args, operation));
      return null;
    case 'setColor':
      target.instance.setColor(...numericArguments(args, 3, operation));
      return null;
    case 'setOpacity':
      target.instance.setOpacity(numericArguments(args, 1, operation)[0]);
      return null;
    case 'setRepresentation': {
      const representation = enumArgument(args, operation, [
        'points',
        'wireframe',
        'surface',
      ]);
      target.instance.setRepresentation(
        { points: 0, wireframe: 1, surface: 2 }[representation],
      );
      return null;
    }
    case 'setLineWidth':
      target.instance.setLineWidth(numericArguments(args, 1, operation)[0]);
      return null;
    case 'addActor':
    case 'removeActor': {
      expectArguments(args, 1, operation);
      const actor = objectArgument(
        session,
        args,
        0,
        ['actor', 'imageActor'],
        operation,
      );
      target.instance[operation](actor.instance);
      return null;
    }
    case 'addVolume':
    case 'removeVolume': {
      expectArguments(args, 1, operation);
      const volume = objectArgument(
        session,
        args,
        0,
        ['volume'],
        operation,
      );
      target.instance[operation](volume.instance);
      return null;
    }
    case 'setBackground':
      target.instance.setBackground(...numericArguments(args, 3, operation));
      return null;
    case 'setActiveCamera': {
      expectArguments(args, 1, operation);
      const camera = objectArgument(
        session,
        args,
        0,
        ['camera'],
        operation,
      );
      target.instance.setActiveCamera(camera.instance);
      return null;
    }
    case 'resetCamera':
      expectArguments(args, 0, operation);
      target.instance.resetCamera();
      return null;
    case 'setPosition':
      target.instance.setPosition(...numericArguments(args, 3, operation));
      return null;
    case 'setFocalPoint':
      target.instance.setFocalPoint(...numericArguments(args, 3, operation));
      return null;
    case 'setViewUp':
      target.instance.setViewUp(...numericArguments(args, 3, operation));
      return null;
    case 'setParallelProjection':
      target.instance.setParallelProjection(booleanArgument(args, operation));
      return null;
    case 'setParallelScale':
      target.instance.setParallelScale(
        numericArguments(args, 1, operation)[0],
      );
      return null;
    case 'setClippingRange':
      target.instance.setClippingRange(
        ...numericArguments(args, 2, operation),
      );
      return null;
    case 'azimuth':
    case 'elevation':
    case 'roll':
    case 'zoom':
    case 'dolly':
      target.instance[operation](numericArguments(args, 1, operation)[0]);
      return null;
    case 'setWindow':
    case 'setLevel':
    case 'setClosestPoint':
    case 'setColorRegions':
      fail(`${operation} is unavailable in the vtk.js backend`);
      break;
    default:
      fail(`operation ${operation} is not whitelisted`);
  }
};

export const getCapabilities = () => ({
  supportedObjectTypes: [...supportedObjectTypes],
  supportedScalarTypes: [...supportedScalarTypes],
  maxImageBytes: maximumImageBytes,
  supportsRendering: canRender(),
  limitations: Object.entries(limitations).map(([capability, reason]) => ({
    capability,
    reason,
  })),
});

export const openSession = async (renderTargetFactory = createRenderTarget) => {
  const sessionId = nextSessionId++;
  sessions.set(sessionId, {
    objects: new Map(),
    renderTarget: null,
    renderTargetFactory,
  });
  return sessionId;
};

export const createObject = async (sessionId, type) => {
  const session = sessionFor(sessionId);
  expectString(type, 'object type');
  const factory = objectFactories[type];
  if (!factory) {
    if (type === 'imageData') {
      fail('imageData must be created with createImageData');
    }
    if (type === 'algorithmOutput') {
      fail('algorithmOutput must be obtained with getOutputPort');
    }
    fail(`object type ${type} is not supported by vtk.js`);
  }
  return addObject(session, type, factory());
};

export const createImageData = async (sessionId, input) => {
  const session = sessionFor(sessionId);
  return addObject(session, 'imageData', createScalarImage(input));
};

export const invoke = async (
  sessionId,
  targetHandle,
  operation,
  args = [],
) => {
  const session = sessionFor(sessionId);
  const target = objectFor(session, targetHandle);
  expectString(operation, 'operation');
  const allowedTargets = operationTargetTypes[operation];
  if (!allowedTargets) fail(`operation ${operation} is not whitelisted`);
  if (!allowedTargets.includes(target.type)) {
    if (allowedTargets.length === 0) {
      fail(`${operation} is unavailable in the vtk.js backend`);
    }
    fail(`${operation} is not allowed on ${target.type}`);
  }
  return invokeOperation(session, target, operation, args);
};

export const destroyObject = async (sessionId, handle) => {
  const session = sessionFor(sessionId);
  const record = objectFor(session, handle);
  session.renderTarget?.detach(record.instance);
  session.objects.delete(handle);
  if (record.owned && typeof record.instance.delete === 'function') {
    record.instance.delete();
  }
};

const validateNormalizedViewport = (viewport, name) => {
  if (!viewport || typeof viewport !== 'object') {
    fail(`${name} is required`);
  }
  const left = expectUnitInterval(viewport.left, `${name}.left`);
  const bottom = expectUnitInterval(viewport.bottom, `${name}.bottom`);
  const right = expectUnitInterval(viewport.right, `${name}.right`);
  const top = expectUnitInterval(viewport.top, `${name}.top`);
  if (left >= right) fail(`${name}.left must be less than right`);
  if (bottom >= top) fail(`${name}.bottom must be less than top`);
  return [left, bottom, right, top];
};

const viewportsOverlap = (first, second) =>
  first[0] < second[2] &&
  second[0] < first[2] &&
  first[1] < second[3] &&
  second[1] < first[3];

export const renderLayout = async (
  sessionId,
  layers,
  viewport,
  primaryLayer = 0,
) => {
  const session = sessionFor(sessionId);
  if (!Array.isArray(layers) || layers.length === 0) {
    fail('layers must contain at least one render layer');
  }
  if (layers.length > maximumRenderLayers) {
    fail(`layers must contain at most ${maximumRenderLayers} render layers`);
  }
  if (!viewport || typeof viewport !== 'object') {
    fail('viewport is required');
  }
  const width = expectPositiveInteger(viewport.width, 'viewport width');
  const height = expectPositiveInteger(viewport.height, 'viewport height');
  const primary = expectNonNegativeInteger(primaryLayer, 'primaryLayer');
  if (primary >= layers.length) {
    fail('primaryLayer must identify a render layer');
  }

  const rendererHandles = new Set();
  const validatedLayers = [];
  for (let index = 0; index < layers.length; index++) {
    const layer = layers[index];
    if (!layer || typeof layer !== 'object') {
      fail(`layers[${index}] is required`);
    }
    const rendererHandle = expectPositiveInteger(
      layer.renderer,
      `layers[${index}].renderer`,
    );
    if (rendererHandles.has(rendererHandle)) {
      fail(`layers[${index}].renderer is duplicated`);
    }
    rendererHandles.add(rendererHandle);
    const renderer = objectFor(
      session,
      rendererHandle,
      ['renderer'],
      `layers[${index}].renderer`,
    );
    const normalizedViewport = validateNormalizedViewport(
      layer.viewport,
      `layers[${index}].viewport`,
    );
    for (let previous = 0; previous < index; previous++) {
      if (
        viewportsOverlap(
          normalizedViewport,
          validatedLayers[previous].viewport,
        )
      ) {
        fail(`layers[${index}].viewport overlaps another render layer`);
      }
    }
    validatedLayers.push({
      renderer: renderer.instance,
      viewport: normalizedViewport,
    });
  }

  const renderTarget = (session.renderTarget ??= session.renderTargetFactory());
  try {
    return await renderTarget.renderLayout(
      validatedLayers,
      width,
      height,
      primary,
    );
  } catch (error) {
    session.renderTarget = null;
    renderTarget.dispose();
    throw error;
  }
};

export const render = async (sessionId, rendererHandle, viewport) =>
  renderLayout(
    sessionId,
    [
      {
        renderer: rendererHandle,
        viewport: { left: 0, bottom: 0, right: 1, top: 1 },
      },
    ],
    viewport,
    0,
  );

export const closeSession = async (sessionId) => {
  expectPositiveInteger(sessionId, 'sessionId');
  const session = sessions.get(sessionId);
  if (!session) return;
  sessions.delete(sessionId);
  session.renderTarget?.dispose();
  for (const record of Array.from(session.objects.values()).reverse()) {
    if (record.owned && typeof record.instance.delete === 'function') {
      record.instance.delete();
    }
  }
  session.objects.clear();
};
