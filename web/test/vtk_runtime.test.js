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
  destroyObject,
  getCapabilities,
  invoke,
  openSession,
} = await import('../src/vtk_runtime.js');

test('merges contour points for connected-region extraction', () => {
  const contour = createFlyingEdges3D();
  try {
    assert.equal(contour.getMergePoints(), true);
  } finally {
    contour.delete();
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
