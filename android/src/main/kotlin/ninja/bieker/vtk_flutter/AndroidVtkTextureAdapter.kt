package ninja.bieker.vtk_flutter

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

internal class AndroidVtkTextureAdapter(
    messenger: BinaryMessenger,
    textures: TextureRegistry,
) : MethodChannel.MethodCallHandler, AutoCloseable {
    private val channel = MethodChannel(messenger, channelName)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val controller = AndroidSessionViewController(
        textureFactory = AndroidPresentationTextureFactory { viewport ->
            FlutterAndroidPresentationTexture.create(
                textures = textures,
                viewport = viewport,
            )
        },
        native = object : AndroidNativePresentation {
            override val available: Boolean
                get() = NativeLibrary.available

            override fun create(
                presentationApiAddress: Long,
                nativeSessionAddress: Long,
                texture: AndroidPresentationTexture,
                viewport: AndroidViewport,
            ): Long {
                val surface = checkNotNull(texture.surface) {
                    "Android presentation texture has no native surface"
                }
                return nativeCreate(
                    presentationApiAddress,
                    nativeSessionAddress,
                    surface,
                    viewport.width,
                    viewport.height,
                )
            }

            override fun attach(handle: Long) = nativeAttach(handle)

            override fun resize(handle: Long, viewport: AndroidViewport) =
                nativeResize(handle, viewport.width, viewport.height)

            override fun recreateGraphicsContext(
                handle: Long,
                texture: AndroidPresentationTexture,
                viewport: AndroidViewport,
            ) {
                val surface = checkNotNull(texture.surface) {
                    "Android presentation texture has no native surface"
                }
                nativeRecreateGraphicsContext(
                    handle,
                    surface,
                    viewport.width,
                    viewport.height,
                )
            }

            override fun destroy(handle: Long) = nativeDestroy(handle)
        },
        executorFactory = AndroidSessionExecutorFactory {
            JavaAndroidSessionExecutor(
                Executors.newSingleThreadExecutor { task ->
                    Thread(task, "vtk-flutter-presentation").apply { isDaemon = true }
                },
            )
        },
        dispatch = { completion -> mainHandler.post(completion) },
        onCloseFailure = { error ->
            Log.e(logTag, "VTK view disposal during plugin detach failed", error)
        },
    )

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        controller.onMethodCall(call, result)
    }

    override fun close() {
        channel.setMethodCallHandler(null)
        controller.close()
    }

    private external fun nativeCreate(
        presentationApiAddress: Long,
        nativeSessionAddress: Long,
        surface: Surface,
        width: Int,
        height: Int,
    ): Long

    private external fun nativeAttach(handle: Long)

    private external fun nativeResize(handle: Long, width: Int, height: Int)

    private external fun nativeRecreateGraphicsContext(
        handle: Long,
        surface: Surface,
        width: Int,
        height: Int,
    )

    private external fun nativeDestroy(handle: Long)

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
        const val logTag = "vtk_flutter"
    }
}

internal class AndroidSessionViewController(
    private val textureFactory: AndroidPresentationTextureFactory,
    private val native: AndroidNativePresentation,
    private val executorFactory: AndroidSessionExecutorFactory,
    private val dispatch: ((() -> Unit) -> Unit),
    private val onCloseFailure: (Throwable) -> Unit,
) : MethodChannel.MethodCallHandler, AutoCloseable {
    private val views = mutableMapOf<Long, AndroidSessionView>()

    @Volatile
    private var closed = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(androidCapabilities(available = native.available))
            "createView" -> createView(call = call, result = result)
            "presentFrame" -> presentFrame(arguments = call.arguments, result = result)
            "status" -> status(arguments = call.arguments, result = result)
            "resize" -> resize(call = call, result = result)
            "recreateGraphicsContext" -> recreateGraphicsContext(
                arguments = call.arguments,
                result = result,
            )
            "disposeView" -> disposeView(arguments = call.arguments, result = result)
            else -> result.notImplemented()
        }
    }

    private fun createView(call: MethodCall, result: MethodChannel.Result) {
        val viewport = readViewport(call = call, result = result) ?: return
        val presentationApiAddress = readPresentationApiAddress(call.arguments)
        if (presentationApiAddress == null) {
            result.error(
                "invalid_presentation_api",
                "A positive VTK presentation API address is required",
                null,
            )
            return
        }
        val nativeSessionAddress = readNativeSessionAddress(call.arguments)
        if (nativeSessionAddress == null) {
            result.invalidNativeSessionError()
            return
        }
        createView(
            viewport = viewport,
            presentationApiAddress = presentationApiAddress,
            nativeSessionAddress = nativeSessionAddress,
            result = result,
        )
    }

    private fun createView(
        viewport: AndroidViewport,
        presentationApiAddress: Long,
        nativeSessionAddress: Long,
        result: MethodChannel.Result,
    ) {
        if (closed) {
            result.disposedError()
            return
        }
        val existing = views[nativeSessionAddress]
        if (existing != null) {
            if (existing.presentationApiAddress != presentationApiAddress) {
                result.error(
                    "invalid_state",
                    "The session view uses a different presentation API",
                    null,
                )
                return
            }
            if (existing.disposing || existing.initializing) {
                existing.pendingCreations += PendingCreation(
                    viewport = viewport,
                    presentationApiAddress = presentationApiAddress,
                    result = result,
                )
                return
            }
            if (!existing.ready || existing.nativeHandle == 0L || existing.texture == null) {
                result.error(
                    "invalid_state",
                    "Dispose the incomplete Android VTK view before retrying",
                    null,
                )
                return
            }
            resizeExistingView(view = existing, viewport = viewport, result = result) {
                result.success(viewResult(textureId = existing.texture?.id ?: -1L))
            }
            return
        }

        if (!native.available) {
            result.error(
                "vtk_unavailable",
                "The Android VTK native library is unavailable",
                null,
            )
            return
        }

        val view = AndroidSessionView(
            nativeSessionAddress = nativeSessionAddress,
            presentationApiAddress = presentationApiAddress,
            viewport = viewport,
            executor = executorFactory.create(),
        )
        views[nativeSessionAddress] = view
        val texture = try {
            textureFactory.create(viewport)
        } catch (error: Throwable) {
            views.remove(nativeSessionAddress)
            view.executor.shutdown()
            result.error("vtk_create_failed", error.message ?: error.toString(), null)
            return
        }
        view.texture = texture
        view.initializing = true
        view.presentationEpoch.incrementAndGet()
        val epoch = view.presentationEpoch.get()
        try {
            texture.setOnFrameConsumedListener {
                if (view.presentationEpoch.get() == epoch) {
                    view.presentedFrameCount.incrementAndGet()
                    view.presentedFrameId.set(view.submittedFrameId.get())
                }
            }
        } catch (error: Throwable) {
            view.initializing = false
            var cleanupFailure: Throwable? = null
            try {
                releaseViewResources(view)
                views.remove(nativeSessionAddress, view)
                view.executor.shutdown()
            } catch (cleanupError: Throwable) {
                cleanupFailure = cleanupError
            }
            result.error(
                "vtk_create_failed",
                error.withCleanupFailure(cleanupFailure),
                null,
            )
            return
        }

        view.executor.execute {
            var failure: Throwable? = null
            try {
                val handle = native.create(
                    presentationApiAddress = presentationApiAddress,
                    nativeSessionAddress = nativeSessionAddress,
                    texture = texture,
                    viewport = viewport,
                )
                check(handle > 0L) { "Native VTK initialization returned an invalid view handle" }
                view.nativeHandle = handle
                native.attach(handle)
            } catch (error: Throwable) {
                failure = error
            }
            dispatch {
                view.initializing = false
                val creationFailure = failure
                when {
                    view.disposing || closed -> result.disposedError()
                    creationFailure == null -> {
                        view.ready = true
                        view.graphicsContextGeneration.set(1)
                        result.success(viewResult(textureId = texture.id))
                        drainPendingCreations(view)
                    }
                    view.nativeHandle == 0L -> {
                        var cleanupFailure: Throwable? = null
                        try {
                            releaseViewResources(view)
                            views.remove(nativeSessionAddress, view)
                            view.executor.shutdown()
                        } catch (error: Throwable) {
                            cleanupFailure = error
                        }
                        result.error(
                            "vtk_create_failed",
                            creationFailure.withCleanupFailure(cleanupFailure),
                            null,
                        )
                        if (cleanupFailure == null) {
                            failPendingCreations(
                                view = view,
                                code = "vtk_create_failed",
                                failure = creationFailure,
                            )
                        } else {
                            drainPendingCreations(view)
                        }
                    }
                    else -> {
                        result.error(
                            "vtk_create_failed",
                            creationFailure.message ?: creationFailure.toString(),
                            null,
                        )
                        drainPendingCreations(view)
                    }
                }
            }
        }
    }

    private fun presentFrame(arguments: Any?, result: MethodChannel.Result) {
        val view = viewForArguments(arguments = arguments, result = result) ?: return
        if (!view.ready || view.disposing) {
            result.notInitializedError()
            return
        }
        val frameId = view.submittedFrameId.incrementAndGet()
        result.success(
            mapOf(
                "frameId" to frameId,
                "presentedFrameCount" to view.presentedFrameCount.get(),
                "presentedFrameId" to view.presentedFrameId.get(),
                "graphicsContextGeneration" to view.graphicsContextGeneration.get(),
                "handoffMode" to handoffMode,
            ),
        )
    }

    private fun status(arguments: Any?, result: MethodChannel.Result) {
        val view = viewForArguments(arguments = arguments, result = result) ?: return
        result.success(view.status())
    }

    private fun resize(call: MethodCall, result: MethodChannel.Result) {
        val view = viewForArguments(arguments = call.arguments, result = result) ?: return
        val viewport = readViewport(call = call, result = result) ?: return
        resizeExistingView(view = view, viewport = viewport, result = result) {
            result.success(null)
        }
    }

    private fun resizeExistingView(
        view: AndroidSessionView,
        viewport: AndroidViewport,
        result: MethodChannel.Result,
        completion: () -> Unit,
    ) {
        if (viewport == view.viewport && view.ready) {
            completion()
            return
        }
        submitNative(view = view, result = result, errorCode = "vtk_resize_failed") { handle ->
            val texture = checkNotNull(view.texture) { "Create a VTK view before resizing it" }
            texture.resize(viewport)
            native.resize(handle = handle, viewport = viewport)
            dispatch {
                view.viewport = viewport
                completion()
            }
            noResult
        }
    }

    private fun recreateGraphicsContext(arguments: Any?, result: MethodChannel.Result) {
        val view = viewForArguments(arguments = arguments, result = result) ?: return
        submitNative(view = view, result = result, errorCode = "vtk_context_failed") { handle ->
            val texture = checkNotNull(view.texture) {
                "Create a VTK view before recreating its context"
            }
            native.recreateGraphicsContext(
                handle = handle,
                texture = texture,
                viewport = view.viewport,
            )
            val generation = view.graphicsContextGeneration.incrementAndGet()
            mapOf("graphicsContextGeneration" to generation)
        }
    }

    private fun submitNative(
        view: AndroidSessionView,
        result: MethodChannel.Result,
        errorCode: String,
        operation: (Long) -> Any?,
    ) {
        if (closed || view.disposing) {
            result.disposedError()
            return
        }
        if (!view.ready) {
            result.notInitializedError()
            return
        }
        view.executor.execute {
            try {
                val handle = view.nativeHandle
                check(handle != 0L && view.ready && !view.disposing) {
                    "Create a VTK view before using it"
                }
                val value = operation(handle)
                if (value !== noResult) dispatch { result.success(value) }
            } catch (error: Throwable) {
                dispatch { result.error(errorCode, error.message ?: error.toString(), null) }
            }
        }
    }

    private fun disposeView(arguments: Any?, result: MethodChannel.Result) {
        val nativeSessionAddress = readNativeSessionAddress(arguments)
        if (nativeSessionAddress == null) {
            result.invalidNativeSessionError()
            return
        }
        val view = views[nativeSessionAddress]
        if (view == null) {
            result.success(null)
            return
        }
        disposeView(view = view, result = result, shutDownAfterDispose = false)
    }

    private fun disposeView(
        view: AndroidSessionView,
        result: MethodChannel.Result?,
        shutDownAfterDispose: Boolean,
    ) {
        result?.let(view.pendingDisposals::add)
        view.shutDownAfterDispose = view.shutDownAfterDispose || shutDownAfterDispose
        if (view.disposing) return
        view.disposing = true
        view.ready = false
        view.pendingTextureUnregistrations = if (view.texture == null) 0 else 1
        view.executor.execute {
            var failure: Throwable? = null
            try {
                val handle = view.nativeHandle
                if (handle != 0L) native.destroy(handle)
                view.nativeHandle = 0L
            } catch (error: Throwable) {
                failure = error
            }
            dispatch {
                var disposalFailure = failure
                view.disposing = false
                if (disposalFailure == null) {
                    try {
                        releaseViewResources(view)
                    } catch (error: Throwable) {
                        disposalFailure = error
                    }
                }
                if (disposalFailure == null) {
                    views.remove(view.nativeSessionAddress, view)
                    completeDisposals(view = view, failure = null)
                    val pendingCreations = view.pendingCreations.toList()
                    view.pendingCreations.clear()
                    view.executor.shutdown()
                    pendingCreations.forEach { creation ->
                        createView(
                            viewport = creation.viewport,
                            presentationApiAddress = creation.presentationApiAddress,
                            nativeSessionAddress = view.nativeSessionAddress,
                            result = creation.result,
                        )
                    }
                } else {
                    completeDisposals(view = view, failure = disposalFailure)
                    failPendingCreations(
                        view = view,
                        code = "vtk_dispose_failed",
                        failure = disposalFailure,
                    )
                    if (view.shutDownAfterDispose) {
                        onCloseFailure(disposalFailure)
                        view.executor.shutdown()
                    }
                }
            }
        }
    }

    private fun completeDisposals(view: AndroidSessionView, failure: Throwable?) {
        val completions = view.pendingDisposals.toList()
        view.pendingDisposals.clear()
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
    }

    private fun drainPendingCreations(view: AndroidSessionView) {
        if (view.disposing) return
        val pending = view.pendingCreations.toList()
        view.pendingCreations.clear()
        pending.forEach { creation ->
            createView(
                viewport = creation.viewport,
                presentationApiAddress = creation.presentationApiAddress,
                nativeSessionAddress = view.nativeSessionAddress,
                result = creation.result,
            )
        }
    }

    private fun failPendingCreations(
        view: AndroidSessionView,
        code: String,
        failure: Throwable,
    ) {
        val pending = view.pendingCreations.toList()
        view.pendingCreations.clear()
        pending.forEach { creation ->
            creation.result.error(code, failure.message ?: failure.toString(), null)
        }
    }

    private fun viewForArguments(
        arguments: Any?,
        result: MethodChannel.Result,
    ): AndroidSessionView? {
        val nativeSessionAddress = readNativeSessionAddress(arguments)
        if (nativeSessionAddress == null) {
            result.invalidNativeSessionError()
            return null
        }
        val view = views[nativeSessionAddress]
        if (view == null) result.notInitializedError()
        return view
    }

    private fun releaseViewResources(view: AndroidSessionView) {
        view.presentationEpoch.incrementAndGet()
        view.texture?.release()
        view.texture = null
        view.ready = false
        view.pendingTextureUnregistrations = 0
        view.graphicsContextGeneration.set(0)
        view.submittedFrameId.set(0)
        view.presentedFrameCount.set(0)
        view.presentedFrameId.set(0)
    }

    override fun close() {
        if (closed) return
        closed = true
        views.values.toList().forEach { view ->
            disposeView(view = view, result = null, shutDownAfterDispose = true)
        }
    }

    private companion object {
        const val maximumFrameBytes = 256 * 1024 * 1024
        const val maximumViewportDimension = 8192
        const val bytesPerPixel = 4L
        const val graphicsSupport = "CPU RGBA / ANativeWindow SurfaceTexture"
        const val handoffMode = "surface_texture_cpu_rgba"
        val noResult = Any()

        fun readViewport(call: MethodCall, result: MethodChannel.Result): AndroidViewport? {
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
            return AndroidViewport(width = width, height = height)
        }
    }
}

internal data class AndroidViewport(val width: Int, val height: Int)

internal fun interface AndroidPresentationTextureFactory {
    fun create(viewport: AndroidViewport): AndroidPresentationTexture
}

internal interface AndroidPresentationTexture {
    val id: Long
    val surface: Surface?

    fun resize(viewport: AndroidViewport)

    fun setOnFrameConsumedListener(listener: () -> Unit)

    fun release()
}

private class FlutterAndroidPresentationTexture private constructor(
    private val entry: TextureRegistry.SurfaceTextureEntry,
    override val surface: Surface,
) : AndroidPresentationTexture {
    private var surfaceReleased = false
    private var entryReleased = false

    override val id: Long
        get() = entry.id()

    override fun resize(viewport: AndroidViewport) {
        entry.surfaceTexture().setDefaultBufferSize(viewport.width, viewport.height)
    }

    override fun setOnFrameConsumedListener(listener: () -> Unit) {
        entry.setOnFrameConsumedListener(listener)
    }

    override fun release() {
        if (!surfaceReleased) {
            surface.release()
            surfaceReleased = true
        }
        if (!entryReleased) {
            entry.release()
            entryReleased = true
        }
    }

    companion object {
        fun create(
            textures: TextureRegistry,
            viewport: AndroidViewport,
        ): FlutterAndroidPresentationTexture {
            val entry = textures.createSurfaceTexture()
            try {
                entry.surfaceTexture().setDefaultBufferSize(viewport.width, viewport.height)
                return FlutterAndroidPresentationTexture(
                    entry = entry,
                    surface = Surface(entry.surfaceTexture()),
                )
            } catch (error: Throwable) {
                entry.release()
                throw error
            }
        }
    }
}

internal interface AndroidNativePresentation {
    val available: Boolean

    fun create(
        presentationApiAddress: Long,
        nativeSessionAddress: Long,
        texture: AndroidPresentationTexture,
        viewport: AndroidViewport,
    ): Long

    fun attach(handle: Long)

    fun resize(handle: Long, viewport: AndroidViewport)

    fun recreateGraphicsContext(
        handle: Long,
        texture: AndroidPresentationTexture,
        viewport: AndroidViewport,
    )

    fun destroy(handle: Long)
}

internal fun interface AndroidSessionExecutorFactory {
    fun create(): AndroidSessionExecutor
}

internal interface AndroidSessionExecutor {
    fun execute(operation: () -> Unit)

    fun shutdown()
}

private class JavaAndroidSessionExecutor(
    private val executor: ExecutorService,
) : AndroidSessionExecutor {
    override fun execute(operation: () -> Unit) {
        executor.execute(operation)
    }

    override fun shutdown() {
        executor.shutdown()
    }
}

private class AndroidSessionView(
    val nativeSessionAddress: Long,
    val presentationApiAddress: Long,
    @Volatile var viewport: AndroidViewport,
    val executor: AndroidSessionExecutor,
) {
    @Volatile var texture: AndroidPresentationTexture? = null
    @Volatile var nativeHandle = 0L
    @Volatile var initializing = false
    @Volatile var ready = false
    @Volatile var disposing = false
    @Volatile var pendingTextureUnregistrations = 0
    var shutDownAfterDispose = false
    val pendingCreations = mutableListOf<PendingCreation>()
    val pendingDisposals = mutableListOf<MethodChannel.Result>()
    val submittedFrameId = AtomicLong()
    val presentedFrameCount = AtomicLong()
    val presentedFrameId = AtomicLong()
    val presentationEpoch = AtomicLong()
    val graphicsContextGeneration = AtomicLong()

    fun status(): Map<String, Any> = mapOf(
        "textureId" to (texture?.id ?: -1L),
        "ready" to ready,
        "initializing" to initializing,
        "disposing" to disposing,
        "pendingTextureUnregistrations" to pendingTextureUnregistrations,
        "queuedInitializationCount" to pendingCreations.size,
        "presentedFrameCount" to presentedFrameCount.get(),
        "presentedFrameId" to presentedFrameId.get(),
        "graphicsContextGeneration" to graphicsContextGeneration.get(),
        "graphicsSupport" to "CPU RGBA / ANativeWindow SurfaceTexture",
    )
}

private data class PendingCreation(
    val viewport: AndroidViewport,
    val presentationApiAddress: Long,
    val result: MethodChannel.Result,
)

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

private fun MethodChannel.Result.invalidNativeSessionError() {
    error(
        "invalid_native_session",
        "A positive VTK native session address is required",
        null,
    )
}

private fun MethodChannel.Result.notInitializedError() {
    error("vtk_not_initialized", "Create a VTK view for this session first", null)
}

private fun Throwable.withCleanupFailure(cleanupFailure: Throwable?): String {
    val original = message ?: toString()
    if (cleanupFailure == null) return original
    return "$original; cleanup failed: ${cleanupFailure.message ?: cleanupFailure}"
}
