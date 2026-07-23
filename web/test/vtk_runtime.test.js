import assert from 'node:assert/strict';
import test from 'node:test';

globalThis.window = {
  addEventListener() {},
  devicePixelRatio: 1,
  location: { search: '' },
  removeEventListener() {},
};

const {
  closeSession,
  createFlyingEdges3D,
  createImageData,
  createObject,
  createRenderTarget,
  createScalarImage,
  destroyObject,
  getCapabilities,
  invoke,
  openSession,
  render,
  renderLayout,
} = await import('../src/vtk_runtime.js');

const createRenderer = (color) => {
  const aspects = [];
  return {
    aspects,
    color,
    viewport: null,
    getActiveCamera() {
      return {
        getCompositeProjectionMatrix(aspect) {
          aspects.push(aspect);
          const matrix = Array(16).fill(0);
          matrix[0] = aspect;
          matrix[15] = 1;
          return matrix;
        },
      };
    },
    setViewport(...viewport) {
      this.viewport = viewport;
    },
  };
};

const createFakeRenderEnvironment = () => {
  const defaultRenderer = createRenderer('default');
  const renderers = [defaultRenderer];
  const pixels = [];
  let width = 1;
  let height = 1;
  let captureReady;
  let captureCount = 0;
  let renderCount = 0;
  let throwOnRender = false;
  const canvas = {
    addEventListener() {},
    removeEventListener() {},
  };
  const context = {
    COLOR_BUFFER_BIT: 1,
    DEPTH_BUFFER_BIT: 2,
    SCISSOR_TEST: 3,
    clear() {
      pixels.length = 0;
      for (let row = 0; row < height; row++) {
        pixels.push(Array(width).fill('transparent'));
      }
    },
    clearColor() {},
    clearDepth() {},
    colorMask() {},
    depthMask() {},
    enable() {},
    scissor() {},
    viewport() {},
  };
  const apiSpecificRenderWindow = {
    captureNextImage() {
      captureCount++;
      return new Promise((resolve) => {
        captureReady = resolve;
      });
    },
    getCanvas() {
      return canvas;
    },
    getContext() {
      return context;
    },
    setSize(nextWidth, nextHeight) {
      width = nextWidth;
      height = nextHeight;
    },
  };
  const renderWindow = {
    addRenderer(renderer) {
      renderers.push(renderer);
    },
    removeRenderer(renderer) {
      const index = renderers.indexOf(renderer);
      if (index >= 0) renderers.splice(index, 1);
    },
    render() {
      renderCount++;
      if (throwOnRender) throw new Error('injected render failure');
      for (const renderer of renderers) {
        const [left, bottom, right, top] = renderer.viewport;
        const firstColumn = Math.round(left * width);
        const lastColumn = Math.round(right * width);
        const firstRow = height - Math.round(top * height);
        const lastRow = height - Math.round(bottom * height);
        for (let row = firstRow; row < lastRow; row++) {
          for (let column = firstColumn; column < lastColumn; column++) {
            pixels[row][column] = renderer.color;
          }
        }
      }
      captureReady('data:image/png;base64,ZmFrZQ==');
    },
  };
  const genericRenderWindow = {
    delete() {},
    getApiSpecificRenderWindow() {
      return apiSpecificRenderWindow;
    },
    getRenderer() {
      return defaultRenderer;
    },
    getRenderWindow() {
      return renderWindow;
    },
    setContainer() {},
  };
  const container = {
    remove() {},
    style: {},
  };
  const target = createRenderTarget({ container, genericRenderWindow });
  return {
    pixels,
    renderers,
    target,
    get captureCount() {
      return captureCount;
    },
    get renderCount() {
      return renderCount;
    },
    set throwOnRender(value) {
      throwOnRender = value;
    },
  };
};

test('merges contour points for connected-region extraction', () => {
  const contour = createFlyingEdges3D();
  try {
    assert.equal(contour.getMergePoints(), true);
  } finally {
    contour.delete();
  }
});

test('places contour vertices using the row-major image direction', () => {
  const image = createScalarImage({
    bytes: new Uint8Array(
      new Float32Array([-1, 1, -1, 1, -1, 1, -1, 1]).buffer,
    ),
    scalarType: 'float32',
    dimensions: [2, 2, 2],
    componentCount: 1,
    origin: [10, 20, 30],
    spacing: [2, 3, 5],
    direction: [0, 0, 1, 1, 0, 0, 0, 1, 0],
  });
  const contour = createFlyingEdges3D();
  try {
    contour.setInputData(image);
    contour.setContourValue(0);
    contour.update();

    const coordinates = Array.from(
      contour.getOutputData().getPoints().getData(),
    );
    const vertices = [];
    for (let index = 0; index < coordinates.length; index += 3) {
      vertices.push(coordinates.slice(index, index + 3));
    }
    vertices.sort((first, second) => {
      for (let axis = 0; axis < 3; axis++) {
        const difference = first[axis] - second[axis];
        if (difference !== 0) return difference;
      }
      return 0;
    });

    assert.deepEqual(vertices, [
      [10, 21, 30],
      [10, 21, 33],
      [15, 21, 30],
      [15, 21, 33],
    ]);
  } finally {
    contour.delete();
    image.delete();
  }
});

test('reports generic vtk.js capabilities and explicit substitutions', () => {
  const capabilities = getCapabilities();

  assert.equal(capabilities.maxImageBytes, 256 * 1024 * 1024);
  assert.ok(capabilities.supportedObjectTypes.includes('imageData'));
  assert.ok(capabilities.supportedObjectTypes.includes('flyingEdges3D'));
  assert.ok(
    capabilities.supportedObjectTypes.includes('polyDataConnectivityFilter'),
  );
  assert.ok(
    !capabilities.supportedObjectTypes.includes(
      'imageMapToWindowLevelColors',
    ),
  );
  assert.ok(
    capabilities.limitations.some(
      ({ capability, reason }) =>
        capability === 'flyingEdges3D' &&
        reason.includes('ImageMarchingCubes'),
    ),
  );
});

test('renders bottom-left viewports into the expected captured quadrants', async () => {
  const environment = createFakeRenderEnvironment();
  const bottomLeft = createRenderer('red');
  const bottomRight = createRenderer('green');
  const topLeft = createRenderer('blue');
  const topRight = createRenderer('yellow');

  const frame = await environment.target.renderLayout(
    [
      { renderer: bottomLeft, viewport: [0, 0, 0.5, 0.5] },
      { renderer: bottomRight, viewport: [0.5, 0, 1, 0.5] },
      { renderer: topLeft, viewport: [0, 0.5, 0.5, 1] },
      { renderer: topRight, viewport: [0.5, 0.5, 1, 1] },
    ],
    4,
    4,
    0,
  );

  assert.deepEqual(environment.pixels, [
    ['blue', 'blue', 'yellow', 'yellow'],
    ['blue', 'blue', 'yellow', 'yellow'],
    ['red', 'red', 'green', 'green'],
    ['red', 'red', 'green', 'green'],
  ]);
  assert.equal(environment.captureCount, 1);
  assert.equal(environment.renderCount, 1);
  assert.deepEqual(environment.renderers, []);
  assert.equal(frame.width, 4);
  assert.equal(frame.height, 4);
});

test('clears uncovered pixels and reapplies viewports on every layout', async () => {
  const environment = createFakeRenderEnvironment();
  const renderer = createRenderer('red');

  await environment.target.renderLayout(
    [{ renderer, viewport: [0, 0, 1, 1] }],
    4,
    4,
    0,
  );
  renderer.color = 'blue';
  await environment.target.renderLayout(
    [{ renderer, viewport: [0, 0, 0.5, 0.5] }],
    4,
    4,
    0,
  );

  assert.deepEqual(environment.pixels, [
    ['transparent', 'transparent', 'transparent', 'transparent'],
    ['transparent', 'transparent', 'transparent', 'transparent'],
    ['blue', 'blue', 'transparent', 'transparent'],
    ['blue', 'blue', 'transparent', 'transparent'],
  ]);
  assert.equal(environment.renderCount, 2);
  assert.deepEqual(environment.renderers, []);
});

test('uses the primary subviewport pixel aspect for world-to-clip', async () => {
  const environment = createFakeRenderEnvironment();
  const secondary = createRenderer('red');
  const primary = createRenderer('blue');

  const frame = await environment.target.renderLayout(
    [
      { renderer: secondary, viewport: [0, 0, 0.5, 1] },
      { renderer: primary, viewport: [0.5, 0, 0.75, 0.5] },
    ],
    800,
    600,
    1,
  );

  assert.deepEqual(secondary.aspects, []);
  assert.deepEqual(primary.aspects, [2 / 3]);
  assert.equal(frame.worldToClip[0], 2 / 3);
});

test('detaches every renderer when an atomic layout render fails', async () => {
  const environment = createFakeRenderEnvironment();
  const first = createRenderer('red');
  const second = createRenderer('blue');
  environment.throwOnRender = true;

  await assert.rejects(
    environment.target.renderLayout(
      [
        { renderer: first, viewport: [0, 0, 0.5, 1] },
        { renderer: second, viewport: [0.5, 0, 1, 1] },
      ],
      4,
      4,
      0,
    ),
    /injected render failure/,
  );

  assert.deepEqual(environment.renderers, []);
});

test('replaces a failed render target and keeps render as a full viewport wrapper', async () => {
  const calls = [];
  const disposeCounts = [0, 0];
  let targetIndex = 0;
  const targets = [
    {
      async renderLayout(...arguments_) {
        calls.push(arguments_);
        throw new Error('injected capture failure');
      },
      dispose() {
        disposeCounts[0]++;
      },
      detach() {},
    },
    {
      async renderLayout(...arguments_) {
        calls.push(arguments_);
        return {
          pngDataUrl: 'data:image/png;base64,ZmFrZQ==',
          width: arguments_[1],
          height: arguments_[2],
          renderMicroseconds: 1,
          captureMicroseconds: 2,
          worldToClip: Array(16).fill(0),
        };
      },
      dispose() {
        disposeCounts[1]++;
      },
      detach() {},
    },
  ];
  const session = await openSession(() => targets[targetIndex++]);
  try {
    const renderer = await createObject(session, 'renderer');

    await assert.rejects(
      render(session, renderer, { width: 8, height: 4 }),
      /injected capture failure/,
    );
    const frame = await render(session, renderer, { width: 8, height: 4 });

    assert.equal(targetIndex, 2);
    assert.deepEqual(disposeCounts, [1, 0]);
    assert.equal(calls.length, 2);
    for (const [layers, width, height, primaryLayer] of calls) {
      assert.equal(layers.length, 1);
      assert.deepEqual(layers[0].viewport, [0, 0, 1, 1]);
      assert.equal(width, 8);
      assert.equal(height, 4);
      assert.equal(primaryLayer, 0);
    }
    assert.equal(frame.width, 8);
    assert.equal(frame.height, 4);
  } finally {
    await closeSession(session);
  }
  assert.deepEqual(disposeCounts, [1, 1]);
});

test('validates complete layouts before creating a render target', async () => {
  let renderTargetCreations = 0;
  const firstSession = await openSession(() => {
    renderTargetCreations++;
    return {};
  });
  const secondSession = await openSession();
  try {
    const first = await createObject(firstSession, 'renderer');
    const second = await createObject(firstSession, 'renderer');
    const foreign = await createObject(secondSession, 'renderer');
    const viewport = { width: 8, height: 6 };
    const full = { left: 0, bottom: 0, right: 1, top: 1 };

    await assert.rejects(
      renderLayout(firstSession, [], viewport, 0),
      /at least one render layer/,
    );
    await assert.rejects(
      renderLayout(
        firstSession,
        [{ renderer: first, viewport: { ...full, left: Number.NaN } }],
        viewport,
        0,
      ),
      /must be finite/,
    );
    await assert.rejects(
      renderLayout(
        firstSession,
        [
          { renderer: first, viewport: { ...full, right: 0.5 } },
          { renderer: first, viewport: { ...full, left: 0.5 } },
        ],
        viewport,
        0,
      ),
      /is duplicated/,
    );
    await assert.rejects(
      renderLayout(
        firstSession,
        [
          { renderer: first, viewport: { ...full, right: 0.75 } },
          { renderer: second, viewport: { ...full, left: 0.5 } },
        ],
        viewport,
        0,
      ),
      /overlaps another render layer/,
    );
    await assert.rejects(
      renderLayout(
        firstSession,
        [{ renderer: first, viewport: full }],
        viewport,
        1,
      ),
      /must identify a render layer/,
    );
    await assert.rejects(
      renderLayout(
        firstSession,
        [{ renderer: foreign, viewport: full }],
        viewport,
        0,
      ),
      /unknown layers\[0\]\.renderer handle/,
    );
    await assert.rejects(
      render(firstSession, second, { width: 0, height: 6 }),
      /viewport width must be a positive safe integer/,
    );
    assert.equal(renderTargetCreations, 0);
  } finally {
    await closeSession(firstSession);
    await closeSession(secondSession);
  }
});

test('creates scalar images and connects a generic surface pipeline', async () => {
  const session = await openSession();
  try {
    const image = await createImageData(session, {
      bytes: new Uint8Array(new Int16Array(8).buffer),
      scalarType: 'int16',
      dimensions: [2, 2, 2],
      componentCount: 1,
      origin: [0, 0, 0],
      spacing: [1, 1, 1],
      direction: [1, 0, 0, 0, 1, 0, 0, 0, 1],
    });
    const contour = await createObject(session, 'flyingEdges3D');
    await invoke(session, contour, 'setInputData', [image]);
    await invoke(session, contour, 'setIsoValue', [0, 0]);
    const contourOutput = await invoke(session, contour, 'getOutputPort', [0]);
    const connectivity = await createObject(
      session,
      'polyDataConnectivityFilter',
    );
    await invoke(session, connectivity, 'setInputConnection', [
      0,
      contourOutput,
    ]);
    await invoke(session, connectivity, 'setConnectivityMode', [
      'largestRegion',
    ]);
    const output = await invoke(session, connectivity, 'getOutputPort', [0]);
    const mapper = await createObject(session, 'polyDataMapper');
    await invoke(session, mapper, 'setInputConnection', [0, output]);
    const actor = await createObject(session, 'actor');
    await invoke(session, actor, 'setMapper', [mapper]);
    const renderer = await createObject(session, 'renderer');
    await invoke(session, renderer, 'addActor', [actor]);

    assert.ok(Number.isSafeInteger(output));
    assert.ok(output > 0);
  } finally {
    await closeSession(session);
  }
});

test('supports surface placement, lighting, and connectivity modes', async () => {
  const session = await openSession();
  try {
    const connectivity = await createObject(
      session,
      'polyDataConnectivityFilter',
    );
    await invoke(session, connectivity, 'setConnectivityMode', ['allRegions']);
    await invoke(session, connectivity, 'setConnectivityMode', [
      'largestRegion',
    ]);

    const actor = await createObject(session, 'actor');
    await invoke(session, actor, 'setPosition', [1, 2, 3]);
    const property = await createObject(session, 'property');
    await invoke(session, property, 'setAmbient', [0.4]);
    await invoke(session, property, 'setDiffuse', [0.8]);
    await invoke(session, property, 'setSpecular', [0.2]);
    await invoke(session, property, 'setSpecularPower', [18]);

    await assert.rejects(
      invoke(session, connectivity, 'setConnectivityMode', [
        'closestPointRegion',
      ]),
      /does not support closestPointRegion/,
    );
    await assert.rejects(
      invoke(session, connectivity, 'setClosestPoint', [1, 2, 3]),
      /unavailable in the vtk\.js backend/,
    );
    await assert.rejects(
      invoke(session, connectivity, 'setColorRegions', [false]),
      /unavailable in the vtk\.js backend/,
    );
  } finally {
    await closeSession(session);
  }
});

test('accepts every stable scalar image type', async () => {
  const session = await openSession();
  const scalarCases = [
    ['uint8', Uint8Array],
    ['int8', Int8Array],
    ['uint16', Uint16Array],
    ['int16', Int16Array],
    ['uint32', Uint32Array],
    ['int32', Int32Array],
    ['float32', Float32Array],
    ['float64', Float64Array],
  ];
  try {
    for (const [scalarType, ScalarArray] of scalarCases) {
      const image = await createImageData(session, {
        bytes: new Uint8Array(new ScalarArray(2).buffer),
        scalarType,
        dimensions: [2, 1, 1],
        componentCount: 1,
        origin: [0, 0, 0],
        spacing: [1, 1, 1],
        direction: [1, 0, 0, 0, 1, 0, 0, 0, 1],
      });
      assert.ok(Number.isSafeInteger(image));
      assert.ok(image > 0);
    }
  } finally {
    await closeSession(session);
  }
});

test('rejects non-whitelisted types, methods, and handle kinds', async () => {
  const session = await openSession();
  try {
    await assert.rejects(
      createObject(session, 'imageMapToWindowLevelColors'),
      /not supported by vtk\.js/,
    );
    const actor = await createObject(session, 'actor');
    const mapper = await createObject(session, 'polyDataMapper');
    await assert.rejects(
      invoke(session, actor, 'setInputData', [mapper]),
      /not allowed on actor/,
    );
    await assert.rejects(
      invoke(session, actor, 'Delete', []),
      /not whitelisted/,
    );
    await destroyObject(session, mapper);
    await assert.rejects(
      invoke(session, actor, 'setMapper', [mapper]),
      /unknown setMapper argument 0 handle/,
    );
  } finally {
    await closeSession(session);
  }
});

test('keeps object handles scoped to their session', async () => {
  const first = await openSession();
  const second = await openSession();
  try {
    const firstActor = await createObject(first, 'actor');
    await createObject(second, 'actor');
    await assert.rejects(
      invoke(second, firstActor, 'setOpacity', [0.5]),
      /unknown object handle/,
    );
  } finally {
    await closeSession(first);
    await closeSession(second);
  }
});
