package ninja.bieker.vtk_flutter

import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToLong

internal class AndroidVtkTextureAdapter(
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler, AutoCloseable {
    private val channel = MethodChannel(messenger, channelName)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "vtk-flutter-render").apply { isDaemon = true }
    }

    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var nativeHandle = 0L
    private var viewportWidth = 0
    private var viewportHeight = 0
    private var initializing = false
    private var ready = false
    private var disposing = false
    private var pendingTextureUnregistrations = 0
    private var shutDownWorkerAfterDispose = false
    private val pendingCreations = mutableListOf<PendingCreation>()
    private val pendingDisposals = mutableListOf<MethodChannel.Result>()
    private val submittedFrameId = AtomicLong()
    private val presentedFrameCount = AtomicLong()
    private val presentedFrameId = AtomicLong()
    private val presentationEpoch = AtomicLong()
    private val graphicsContextGeneration = AtomicLong()

    @Volatile
    private var closed = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> capabilities(result)
            "createSession" -> createSession(call, result)
            "setVolume" -> setVolume(call, result)
            "render" -> render(call, result)
            "status" -> status(result)
            "resize" -> resize(call, result)
            "recreateGraphicsContext" -> recreateGraphicsContext(result)
            "disposeSession" -> disposeSession(result = result)
            else -> result.notImplemented()
        }
    }

    private fun capabilities(result: MethodChannel.Result) {
        worker.execute {
            val available = NativeLibrary.available && !closed
            postResult {
                result.success(
                    mapOf(
                        "renderModes" to if (available) listOf(1, 2, 3) else emptyList<Int>(),
                        "maxVolumeBytes" to if (available) maximumVolumeBytes else 0,
                        "supportsExternalTexture" to available,
                    ),
                )
            }
        }
    }

    private fun createSession(call: MethodCall, result: MethodChannel.Result) {
        val viewport = readViewport(call, result) ?: return
        createSession(viewport = viewport, result = result)
    }

    private fun createSession(viewport: Viewport, result: MethodChannel.Result) {
        if (closed) {
            result.disposedError()
            return
        }
        if (disposing || initializing) {
            pendingCreations.add(PendingCreation(viewport = viewport, result = result))
            return
        }
        textureEntry?.let { entry ->
            resizeExistingSession(viewport = viewport, result = result) {
                result.success(mapOf("textureId" to entry.id()))
            }
            return
        }

        initializing = true
        worker.execute {
            val available = NativeLibrary.available
            postResult {
                if (closed) {
                    initializing = false
                    result.disposedError()
                    drainPendingCreations()
                } else if (disposing) {
                    initializing = false
                    result.disposedError()
                } else if (!available) {
                    initializing = false
                    result.error(
                        "vtk_unavailable",
                        "The Android VTK native library is unavailable",
                        null,
                    )
                    drainPendingCreations()
                } else {
                    initializeTexture(viewport = viewport, result = result)
                }
            }
        }
    }

    private fun initializeTexture(viewport: Viewport, result: MethodChannel.Result) {
        val entry = textures.createSurfaceTexture()
        entry.surfaceTexture().setDefaultBufferSize(viewport.width, viewport.height)
        val epoch = presentationEpoch.incrementAndGet()
        entry.setOnFrameConsumedListener {
            if (presentationEpoch.get() == epoch) {
                presentedFrameCount.incrementAndGet()
                presentedFrameId.set(submittedFrameId.get())
            }
        }
        val renderSurface = Surface(entry.surfaceTexture())
        textureEntry = entry
        surface = renderSurface
        viewportWidth = viewport.width
        viewportHeight = viewport.height
        resetFrameState()
        worker.execute {
            try {
                nativeHandle = nativeCreate(renderSurface, viewport.width, viewport.height)
                check(nativeHandle != 0L) { "Native VTK initialization returned no session" }
                postResult {
                    initializing = false
                    if (closed || disposing) {
                        result.disposedError()
                    } else {
                        ready = true
                        graphicsContextGeneration.set(1)
                        result.success(mapOf("textureId" to entry.id()))
                    }
                    if (!disposing) drainPendingCreations()
                }
            } catch (error: Throwable) {
                postResult {
                    initializing = false
                    releaseTexture()
                    result.error("vtk_create_failed", error.message ?: error.toString(), null)
                    if (!disposing) drainPendingCreations()
                }
            }
        }
    }

    private fun setVolume(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val voxels = arguments?.get("voxels") as? ByteArray
        val width = (arguments?.get("width") as? Number)?.toInt()
        val height = (arguments?.get("height") as? Number)?.toInt()
        val depth = (arguments?.get("depth") as? Number)?.toInt()
        val indexToPatient = arguments?.get("indexToPatient") as? DoubleArray
        val expectedBytes = if (width != null && height != null && depth != null) {
            width.toLong() * height.toLong() * depth.toLong() * bytesPerVoxel
        } else {
            -1
        }
        if (
            voxels == null || width == null || height == null || depth == null ||
            width <= 0 || height <= 0 || depth <= 0 ||
            width > maximumVolumeDimension || height > maximumVolumeDimension ||
            depth > maximumVolumeDimension ||
            expectedBytes != voxels.size.toLong() || expectedBytes > maximumVolumeBytes ||
            indexToPatient?.size != affineElementCount
        ) {
            result.error(
                "invalid_volume",
                "Expected bounded signed-int16 voxel bytes, dimensions, and a Float64 affine",
                null,
            )
            return
        }
        submitNative(result = result, errorCode = "vtk_volume_failed") { handle ->
            nativeSetVolume(handle, voxels, width, height, depth, indexToPatient)
            null
        }
    }

    private fun render(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val mode = (arguments?.get("mode") as? Number)?.toInt() ?: -1
        val origin = arguments?.get("planeOrigin") as? DoubleArray ?: zeroVector
        val normal = arguments?.get("planeNormal") as? DoubleArray ?: defaultNormal
        if (mode !in 1..3 || origin.size != vectorElementCount || normal.size != vectorElementCount) {
            result.error(
                "invalid_render_request",
                "Expected a supported mode and three-value plane vectors",
                null,
            )
            return
        }
        val windowCenter = (arguments?.get("windowCenter") as? Number)?.toDouble() ?: 350.0
        val windowWidth = (arguments?.get("windowWidth") as? Number)?.toDouble() ?: 1800.0
        val azimuth = (arguments?.get("cameraAzimuthDegrees") as? Number)?.toDouble() ?: 0.0
        val elevation = (arguments?.get("cameraElevationDegrees") as? Number)?.toDouble() ?: 0.0
        val zoom = (arguments?.get("cameraZoom") as? Number)?.toDouble() ?: 1.0
        submitNative(result = result, errorCode = "vtk_render_failed") { handle ->
            val frameId = submittedFrameId.incrementAndGet()
            val metrics = nativeRender(
                handle,
                mode,
                viewportWidth,
                viewportHeight,
                windowCenter,
                windowWidth,
                origin,
                normal,
                azimuth,
                elevation,
                zoom,
            )
            buildFrameMetrics(metrics = metrics, frameId = frameId)
        }
    }

    private fun buildFrameMetrics(metrics: DoubleArray, frameId: Long): Map<String, Any> {
        check(metrics.size == nativeMetricCount) { "Native VTK returned malformed metrics" }
        val values = mutableMapOf<String, Any>(
            "textureId" to (textureEntry?.id() ?: -1L),
            "width" to metrics[metricFrameWidth].roundToLong(),
            "height" to metrics[metricFrameHeight].roundToLong(),
            "volumeBytes" to metrics[metricVolumeBytes].roundToLong(),
            "frameBytes" to metrics[metricFrameBytes].roundToLong(),
            "residentBytes" to (
                metrics[metricVolumeBytes] + metrics[metricSurfaceAllocationBytes]
            ).roundToLong(),
            "renderUs" to metrics[metricRenderMilliseconds].millisecondsToMicroseconds(),
            "blitSubmitUs" to metrics[metricSubmitMilliseconds].millisecondsToMicroseconds(),
            "gpuSyncWaitUs" to metrics[metricGpuWaitMilliseconds].millisecondsToMicroseconds(),
            "readbackUs" to metrics[metricReadbackMilliseconds].millisecondsToMicroseconds(),
            "frameId" to frameId,
            "presentedFrameCount" to presentedFrameCount.get(),
            "presentedFrameId" to presentedFrameId.get(),
            "graphicsContextGeneration" to graphicsContextGeneration.get(),
            "handoffMode" to "surface_texture_egl_swap",
        )
        if (metrics[metricPatientToClipValid] != 0.0) {
            values["patientToClip"] = metrics
                .copyOfRange(metricPatientToClipStart, nativeMetricCount)
                .toList()
        }
        return values
    }

    private fun status(result: MethodChannel.Result) {
        result.success(
            mapOf(
                "textureId" to (textureEntry?.id() ?: -1L),
                "ready" to ready,
                "initializing" to initializing,
                "disposing" to disposing,
                "pendingTextureUnregistrations" to pendingTextureUnregistrations,
                "queuedInitializationCount" to pendingCreations.size,
                "presentedFrameCount" to presentedFrameCount.get(),
                "presentedFrameId" to presentedFrameId.get(),
                "graphicsContextGeneration" to graphicsContextGeneration.get(),
                "graphicsSupport" to graphicsSupport,
            ),
        )
    }

    private fun resize(call: MethodCall, result: MethodChannel.Result) {
        val viewport = readViewport(call, result) ?: return
        resizeExistingSession(viewport = viewport, result = result) { result.success(null) }
    }

    private fun resizeExistingSession(
        viewport: Viewport,
        result: MethodChannel.Result,
        completion: () -> Unit,
    ) {
        if (viewport.width == viewportWidth && viewport.height == viewportHeight && ready) {
            completion()
            return
        }
        val entry = textureEntry
        submitNative(result = result, errorCode = "vtk_resize_failed") { handle ->
            check(entry != null) { "Create a VTK session before resizing it" }
            entry.surfaceTexture().setDefaultBufferSize(viewport.width, viewport.height)
            nativeResize(handle, viewport.width, viewport.height)
            viewportWidth = viewport.width
            viewportHeight = viewport.height
            postResult(completion)
            noResult
        }
    }

    private fun recreateGraphicsContext(result: MethodChannel.Result) {
        val renderSurface = surface
        submitNative(result = result, errorCode = "vtk_context_failed") { handle ->
            check(renderSurface != null) { "Create a VTK session before recreating its context" }
            nativeRecreateGraphicsContext(handle, renderSurface, viewportWidth, viewportHeight)
            val generation = graphicsContextGeneration.incrementAndGet()
            mapOf("graphicsContextGeneration" to generation)
        }
    }

    private fun readViewport(call: MethodCall, result: MethodChannel.Result): Viewport? {
        val arguments = call.arguments as? Map<*, *>
        val width = (arguments?.get("width") as? Number)?.toInt()
        val height = (arguments?.get("height") as? Number)?.toInt()
        val frameBytes = if (width != null && height != null) {
            width.toLong() * height.toLong() * bytesPerPixel
        } else {
            -1
        }
        if (
            width == null || height == null || width <= 0 || height <= 0 ||
            width > maximumViewportDimension || height > maximumViewportDimension ||
            frameBytes > maximumFrameBytes
        ) {
            result.error(
                "invalid_viewport",
                "Viewport dimensions must be positive, bounded, and fit the frame budget",
                null,
            )
            return null
        }
        return Viewport(width = width, height = height)
    }

    private fun submitNative(
        result: MethodChannel.Result,
        errorCode: String,
        operation: (Long) -> Any?,
    ) {
        if (closed || disposing) {
            result.disposedError()
            return
        }
        worker.execute {
            try {
                val handle = nativeHandle
                check(handle != 0L && ready) { "Create a VTK session before using it" }
                val value = operation(handle)
                if (value !== noResult) postResult { result.success(value) }
            } catch (error: Throwable) {
                postResult { result.error(errorCode, error.message ?: error.toString(), null) }
            }
        }
    }

    private fun disposeSession(
        result: MethodChannel.Result? = null,
        shutDownWorker: Boolean = false,
    ) {
        result?.let(pendingDisposals::add)
        shutDownWorkerAfterDispose = shutDownWorkerAfterDispose || shutDownWorker
        if (disposing) return
        if (nativeHandle == 0L && !initializing && textureEntry == null) {
            completeDisposal()
            return
        }

        disposing = true
        ready = false
        pendingTextureUnregistrations = if (textureEntry == null) 0 else 1
        worker.execute {
            try {
                val handle = nativeHandle
                nativeHandle = 0
                if (handle != 0L) nativeDestroy(handle)
            } finally {
                postResult {
                    releaseTexture()
                    disposing = false
                    initializing = false
                    completeDisposal()
                    drainPendingCreations()
                }
            }
        }
    }

    private fun completeDisposal() {
        val completions = pendingDisposals.toList()
        pendingDisposals.clear()
        completions.forEach { it.success(null) }
        if (shutDownWorkerAfterDispose) worker.shutdown()
    }

    private fun drainPendingCreations() {
        if (disposing) return
        val pending = pendingCreations.toList()
        pendingCreations.clear()
        pending.forEach { creation ->
            if (closed) {
                creation.result.disposedError()
            } else {
                createSession(viewport = creation.viewport, result = creation.result)
            }
        }
    }

    override fun close() {
        channel.setMethodCallHandler(null)
        if (closed) return
        closed = true
        disposeSession(shutDownWorker = true)
    }

    private fun releaseTexture() {
        presentationEpoch.incrementAndGet()
        surface?.release()
        surface = null
        textureEntry?.release()
        textureEntry = null
        viewportWidth = 0
        viewportHeight = 0
        ready = false
        pendingTextureUnregistrations = 0
        graphicsContextGeneration.set(0)
        resetFrameState()
    }

    private fun resetFrameState() {
        submittedFrameId.set(0)
        presentedFrameCount.set(0)
        presentedFrameId.set(0)
    }

    private fun postResult(completion: () -> Unit) {
        mainHandler.post(completion)
    }

    private external fun nativeCreate(surface: Surface, width: Int, height: Int): Long

    private external fun nativeSetVolume(
        handle: Long,
        voxels: ByteArray,
        width: Int,
        height: Int,
        depth: Int,
        indexToPatient: DoubleArray,
    )

    private external fun nativeRender(
        handle: Long,
        mode: Int,
        width: Int,
        height: Int,
        windowCenter: Double,
        windowWidth: Double,
        planeOrigin: DoubleArray,
        planeNormal: DoubleArray,
        cameraAzimuthDegrees: Double,
        cameraElevationDegrees: Double,
        cameraZoom: Double,
    ): DoubleArray

    private external fun nativeResize(handle: Long, width: Int, height: Int)

    private external fun nativeRecreateGraphicsContext(
        handle: Long,
        surface: Surface,
        width: Int,
        height: Int,
    )

    private external fun nativeDestroy(handle: Long)

    private data class Viewport(val width: Int, val height: Int)

    private data class PendingCreation(
        val viewport: Viewport,
        val result: MethodChannel.Result,
    )

    private object NativeLibrary {
        val available = try {
            System.loadLibrary("vtk_flutter")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    private companion object {
        const val channelName = "vtk_flutter/session"
        const val maximumVolumeBytes = 256 * 1024 * 1024
        const val maximumFrameBytes = 256 * 1024 * 1024
        const val maximumVolumeDimension = 4096
        const val maximumViewportDimension = 8192
        const val bytesPerVoxel = 2L
        const val bytesPerPixel = 4L
        const val affineElementCount = 16
        const val vectorElementCount = 3
        const val nativeMetricCount = 26
        const val metricVolumeBytes = 0
        const val metricFrameBytes = 1
        const val metricSurfaceAllocationBytes = 2
        const val metricRenderMilliseconds = 3
        const val metricSubmitMilliseconds = 4
        const val metricGpuWaitMilliseconds = 5
        const val metricReadbackMilliseconds = 6
        const val metricFrameWidth = 7
        const val metricFrameHeight = 8
        const val metricPatientToClipValid = 9
        const val metricPatientToClipStart = 10
        const val graphicsSupport = "OpenGL ES 3 / EGL SurfaceTexture"
        val zeroVector = doubleArrayOf(0.0, 0.0, 0.0)
        val defaultNormal = doubleArrayOf(0.0, 0.0, 1.0)
        val noResult = Any()
    }
}

private fun Double.millisecondsToMicroseconds(): Long = (this * 1_000.0).roundToLong()

private fun MethodChannel.Result.disposedError() {
    error("vtk_disposed", "The Android VTK session is disposed", null)
}
