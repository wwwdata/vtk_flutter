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

internal class AndroidVtkTextureAdapter(
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler, AutoCloseable {
    private val channel = MethodChannel(messenger, channelName)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "vtk-flutter-presentation").apply { isDaemon = true }
    }

    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var nativeHandle = 0L
    private var nativeSessionAddress = 0L
    private var presentationApiAddress = 0L
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
            "createView" -> createView(call, result)
            "presentFrame" -> presentFrame(result)
            "status" -> status(result)
            "resize" -> resize(call, result)
            "recreateGraphicsContext" -> recreateGraphicsContext(result)
            "disposeView" -> disposeView(result = result)
            else -> result.notImplemented()
        }
    }

    private fun capabilities(result: MethodChannel.Result) {
        worker.execute {
            val available = NativeLibrary.available && !closed
            postResult { result.success(androidCapabilities(available = available)) }
        }
    }

    private fun createView(call: MethodCall, result: MethodChannel.Result) {
        val viewport = readViewport(call, result) ?: return
        val presentationAddress = readPresentationApiAddress(call.arguments)
        if (presentationAddress == null) {
            result.error(
                "invalid_presentation_api",
                "A positive VTK presentation API address is required",
                null,
            )
            return
        }
        val sessionAddress = readNativeSessionAddress(call.arguments)
        if (sessionAddress == null) {
            result.error(
                "invalid_native_session",
                "A positive VTK native session address is required",
                null,
            )
            return
        }
        createView(
            viewport = viewport,
            presentationApiAddress = presentationAddress,
            nativeSessionAddress = sessionAddress,
            result = result,
        )
    }

    private fun createView(
        viewport: Viewport,
        presentationApiAddress: Long,
        nativeSessionAddress: Long,
        result: MethodChannel.Result,
    ) {
        if (closed) {
            result.disposedError()
            return
        }
        if (disposing || initializing) {
            pendingCreations.add(
                PendingCreation(
                    viewport = viewport,
                    presentationApiAddress = presentationApiAddress,
                    nativeSessionAddress = nativeSessionAddress,
                    result = result,
                ),
            )
            return
        }
        textureEntry?.let { entry ->
            if (
                this.presentationApiAddress != presentationApiAddress ||
                this.nativeSessionAddress != nativeSessionAddress
            ) {
                result.error(
                    "invalid_state",
                    "The active view uses a different presentation API or session",
                    null,
                )
                return
            }
            resizeExistingView(viewport = viewport, result = result) {
                result.success(viewResult(textureId = entry.id()))
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
                    initializeTexture(
                        viewport = viewport,
                        presentationApiAddress = presentationApiAddress,
                        nativeSessionAddress = nativeSessionAddress,
                        result = result,
                    )
                }
            }
        }
    }

    private fun initializeTexture(
        viewport: Viewport,
        presentationApiAddress: Long,
        nativeSessionAddress: Long,
        result: MethodChannel.Result,
    ) {
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
                val handle = nativeCreate(
                    presentationApiAddress,
                    nativeSessionAddress,
                    renderSurface,
                    viewport.width,
                    viewport.height,
                )
                check(handle > 0L) { "Native VTK initialization returned an invalid view handle" }
                nativeHandle = handle
                this.presentationApiAddress = presentationApiAddress
                this.nativeSessionAddress = nativeSessionAddress
                postResult {
                    initializing = false
                    if (closed || disposing) {
                        result.disposedError()
                    } else {
                        ready = true
                        graphicsContextGeneration.set(1)
                        result.success(viewResult(textureId = entry.id()))
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

    private fun presentFrame(result: MethodChannel.Result) {
        if (closed || disposing || !ready || nativeSessionAddress <= 0) {
            result.disposedError()
            return
        }
        val frameId = submittedFrameId.incrementAndGet()
        result.success(
            mapOf(
                "frameId" to frameId,
                "presentedFrameCount" to presentedFrameCount.get(),
                "presentedFrameId" to presentedFrameId.get(),
                "graphicsContextGeneration" to graphicsContextGeneration.get(),
                "handoffMode" to handoffMode,
            ),
        )
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
        resizeExistingView(viewport = viewport, result = result) { result.success(null) }
    }

    private fun resizeExistingView(
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
            check(entry != null) { "Create a VTK view before resizing it" }
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
            check(renderSurface != null) { "Create a VTK view before recreating its context" }
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
                check(handle != 0L && ready) { "Create a VTK view before using it" }
                val value = operation(handle)
                if (value !== noResult) postResult { result.success(value) }
            } catch (error: Throwable) {
                postResult { result.error(errorCode, error.message ?: error.toString(), null) }
            }
        }
    }

    private fun disposeView(
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
            var failure: Throwable? = null
            try {
                val handle = nativeHandle
                if (handle != 0L) nativeDestroy(handle)
                nativeHandle = 0L
            } catch (error: Throwable) {
                failure = error
            }
            postResult {
                val disposalFailure = failure
                if (disposalFailure == null) releaseTexture()
                disposing = false
                initializing = false
                completeDisposal(disposalFailure)
                if (disposalFailure == null) {
                    drainPendingCreations()
                } else {
                    failPendingCreations(disposalFailure)
                }
            }
        }
    }

    private fun completeDisposal(failure: Throwable? = null) {
        val completions = pendingDisposals.toList()
        pendingDisposals.clear()
        completions.forEach { completion ->
            if (failure == null) {
                completion.success(null)
            } else {
                completion.error(
                    "vtk_dispose_failed",
                    failure.message ?: failure.toString(),
                    null,
                )
            }
        }
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
                createView(
                    viewport = creation.viewport,
                    presentationApiAddress = creation.presentationApiAddress,
                    nativeSessionAddress = creation.nativeSessionAddress,
                    result = creation.result,
                )
            }
        }
    }

    private fun failPendingCreations(failure: Throwable) {
        val pending = pendingCreations.toList()
        pendingCreations.clear()
        pending.forEach { creation ->
            creation.result.error(
                "vtk_dispose_failed",
                failure.message ?: failure.toString(),
                null,
            )
        }
    }

    override fun close() {
        channel.setMethodCallHandler(null)
        if (closed) return
        closed = true
        disposeView(shutDownWorker = true)
    }

    private fun releaseTexture() {
        presentationEpoch.incrementAndGet()
        surface?.release()
        surface = null
        textureEntry?.release()
        textureEntry = null
        viewportWidth = 0
        viewportHeight = 0
        nativeSessionAddress = 0
        presentationApiAddress = 0
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

    private external fun nativeCreate(
        presentationApiAddress: Long,
        nativeSessionAddress: Long,
        surface: Surface,
        width: Int,
        height: Int,
    ): Long

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
        val presentationApiAddress: Long,
        val nativeSessionAddress: Long,
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
        const val maximumFrameBytes = 256 * 1024 * 1024
        const val maximumViewportDimension = 8192
        const val bytesPerPixel = 4L
        const val graphicsSupport = "CPU RGBA / ANativeWindow SurfaceTexture"
        const val handoffMode = "surface_texture_cpu_rgba"
        val noResult = Any()
    }
}

internal fun androidCapabilities(available: Boolean): Map<String, Any> = mapOf(
    "backend" to "android",
    "version" to 1,
    "maxUploadBytes" to if (available) 256 * 1024 * 1024 else 0,
    "supportsExternalTexture" to available,
)

internal fun viewResult(textureId: Long): Map<String, Long> =
    mapOf("textureId" to textureId)

internal fun readPresentationApiAddress(arguments: Any?): Long? =
    readPositiveAddress(arguments = arguments, key = "presentationApiAddress")

internal fun readNativeSessionAddress(arguments: Any?): Long? =
    readPositiveAddress(arguments = arguments, key = "nativeSessionAddress")

private fun readPositiveAddress(arguments: Any?, key: String): Long? {
    val value = (arguments as? Map<*, *>)?.get(key)
    val address = when (value) {
        is Byte -> value.toLong()
        is Short -> value.toLong()
        is Int -> value.toLong()
        is Long -> value
        else -> return null
    }
    return address.takeIf { it > 0L }
}

private fun MethodChannel.Result.disposedError() {
    error("vtk_disposed", "The Android VTK view is disposed", null)
}
