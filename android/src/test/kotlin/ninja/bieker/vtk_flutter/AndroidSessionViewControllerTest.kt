package ninja.bieker.vtk_flutter

import android.view.Surface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class AndroidSessionViewControllerTest {
    @Test
    fun routesTwoSessionsToIndependentTexturesAndNativeHandles() {
        val harness = ControllerHarness()

        val firstCreate = harness.call(
            method = "createView",
            arguments = viewArguments(session = 101L, width = 320, height = 240),
        )
        val secondCreate = harness.call(
            method = "createView",
            arguments = viewArguments(session = 202L, width = 640, height = 480),
        )

        val firstTextureId = firstCreate.successMap()["textureId"]
        val secondTextureId = secondCreate.successMap()["textureId"]
        assertNotEquals(firstTextureId, secondTextureId)
        assertEquals(2, harness.native.createdHandles.size)
        assertNotEquals(
            harness.native.handleForSession.getValue(101L),
            harness.native.handleForSession.getValue(202L),
        )
        assertEquals(2, harness.executors.size)

        harness.call(
            method = "resize",
            arguments = viewArguments(session = 101L, width = 800, height = 600),
        ).assertSucceeded()
        harness.call(
            method = "recreateGraphicsContext",
            arguments = mapOf("nativeSessionAddress" to 202L),
        ).assertSucceeded()

        assertEquals(
            listOf(harness.native.handleForSession.getValue(101L)),
            harness.native.resizedHandles,
        )
        assertEquals(
            listOf(harness.native.handleForSession.getValue(202L)),
            harness.native.recreatedHandles,
        )
        harness.call(
            method = "presentFrame",
            arguments = mapOf("nativeSessionAddress" to 101L),
        ).assertSucceeded()
        harness.textures.single { it.id == firstTextureId }.consumeFrame()
        val firstStatus = harness.call(
            method = "status",
            arguments = mapOf("nativeSessionAddress" to 101L),
        ).successMap()
        val secondStatus = harness.call(
            method = "status",
            arguments = mapOf("nativeSessionAddress" to 202L),
        ).successMap()
        assertEquals(1L, firstStatus["presentedFrameCount"])
        assertEquals(0L, secondStatus["presentedFrameCount"])
        assertEquals(1L, firstStatus["graphicsContextGeneration"])
        assertEquals(2L, secondStatus["graphicsContextGeneration"])

        harness.call(
            method = "disposeView",
            arguments = mapOf("nativeSessionAddress" to 101L),
        ).assertSucceeded()

        assertTrue(harness.textures.single { it.id == firstTextureId }.released)
        assertFalse(harness.textures.single { it.id == secondTextureId }.released)
        assertTrue(harness.executors.first().shutDown)
        assertFalse(harness.executors.last().shutDown)
        assertTrue(
            harness.call(
                method = "status",
                arguments = mapOf("nativeSessionAddress" to 202L),
            ).successMap()["ready"] as Boolean,
        )
    }

    @Test
    fun creatingTheSameSessionIsIdempotentAndResizesItsExistingTexture() {
        val harness = ControllerHarness()
        val first = harness.call(
            method = "createView",
            arguments = viewArguments(session = 303L, width = 320, height = 240),
        )

        val second = harness.call(
            method = "createView",
            arguments = viewArguments(session = 303L, width = 1024, height = 768),
        )

        assertEquals(first.successMap(), second.successMap())
        assertEquals(1, harness.native.createdHandles.size)
        assertEquals(1, harness.textures.size)
        assertEquals(AndroidViewport(width = 1024, height = 768), harness.textures.single().size)
        assertEquals(
            listOf(harness.native.handleForSession.getValue(303L)),
            harness.native.resizedHandles,
        )

        val mismatchedApi = harness.call(
            method = "createView",
            arguments = viewArguments(
                session = 303L,
                width = 1024,
                height = 768,
                presentationApi = 999L,
            ),
        )
        assertEquals("invalid_state", mismatchedApi.errorCode)
    }

    @Test
    fun failedDisposalIsIsolatedAndCanBeRetried() {
        val harness = ControllerHarness()
        val firstTextureId = harness.call(
            method = "createView",
            arguments = viewArguments(session = 404L, width = 320, height = 240),
        ).successMap()["textureId"]
        harness.call(
            method = "createView",
            arguments = viewArguments(session = 505L, width = 640, height = 480),
        ).assertSucceeded()
        val failingHandle = harness.native.handleForSession.getValue(404L)
        harness.native.destroyFailuresRemaining[failingHandle] = 1

        val firstDisposal = harness.call(
            method = "disposeView",
            arguments = mapOf("nativeSessionAddress" to 404L),
        )

        assertEquals("vtk_dispose_failed", firstDisposal.errorCode)
        assertFalse(harness.textures.single { it.id == firstTextureId }.released)
        assertFalse(harness.executors.first().shutDown)
        assertTrue(
            harness.call(
                method = "status",
                arguments = mapOf("nativeSessionAddress" to 505L),
            ).successMap()["ready"] as Boolean,
        )

        harness.call(
            method = "disposeView",
            arguments = mapOf("nativeSessionAddress" to 404L),
        ).assertSucceeded()
        assertTrue(harness.textures.single { it.id == firstTextureId }.released)
        assertTrue(harness.executors.first().shutDown)

        harness.call(
            method = "disposeView",
            arguments = mapOf("nativeSessionAddress" to 404L),
        ).assertSucceeded()
    }

    @Test
    fun failedAttachmentKeepsTheIncompleteViewAvailableForCleanup() {
        val harness = ControllerHarness()
        harness.native.attachFailuresRemaining[606L] = 1

        val creation = harness.call(
            method = "createView",
            arguments = viewArguments(session = 606L, width = 320, height = 240),
        )

        assertEquals("vtk_create_failed", creation.errorCode)
        assertEquals(1, harness.native.createdHandles.size)
        assertFalse(harness.textures.single().released)
        assertEquals(
            "invalid_state",
            harness.call(
                method = "createView",
                arguments = viewArguments(session = 606L, width = 320, height = 240),
            ).errorCode,
        )

        harness.call(
            method = "disposeView",
            arguments = mapOf("nativeSessionAddress" to 606L),
        ).assertSucceeded()
        assertTrue(harness.textures.single().released)
        assertEquals(harness.native.createdHandles, harness.native.destroyedHandles)
    }

    @Test
    fun disposingAnUnknownValidSessionIsIdempotent() {
        val harness = ControllerHarness()

        val result = harness.call(
            method = "disposeView",
            arguments = mapOf("nativeSessionAddress" to 707L),
        )

        result.assertSucceeded()
        assertNull(result.value)
        assertTrue(harness.native.destroyedHandles.isEmpty())
    }

    @Test
    fun initializationAndDisposalAreQueuedOnlyWithinTheirSession() {
        val executors = mutableListOf<QueuedSessionExecutor>()
        val harness = ControllerHarness(
            executorFactory = AndroidSessionExecutorFactory {
                QueuedSessionExecutor().also(executors::add)
            },
        )
        val firstCreation = harness.call(
            method = "createView",
            arguments = viewArguments(session = 808L, width = 320, height = 240),
        )
        val secondCreation = harness.call(
            method = "createView",
            arguments = viewArguments(session = 909L, width = 640, height = 480),
        )
        val firstDisposal = harness.call(
            method = "disposeView",
            arguments = mapOf("nativeSessionAddress" to 808L),
        )

        assertFalse(firstCreation.completed)
        assertFalse(secondCreation.completed)
        assertFalse(firstDisposal.completed)
        executors[1].runNext()
        secondCreation.assertSucceeded()
        assertFalse(firstCreation.completed)
        assertFalse(firstDisposal.completed)

        executors[0].runNext()
        assertEquals("vtk_disposed", firstCreation.errorCode)
        assertFalse(firstDisposal.completed)
        executors[0].runNext()
        firstDisposal.assertSucceeded()
        assertTrue(harness.textures.first().released)
        assertFalse(harness.textures.last().released)
        assertTrue(
            harness.call(
                method = "status",
                arguments = mapOf("nativeSessionAddress" to 909L),
            ).successMap()["ready"] as Boolean,
        )
    }

    @Test
    fun closeDisposesEveryCompleteAndIncompleteSession() {
        val harness = ControllerHarness()
        harness.call(
            method = "createView",
            arguments = viewArguments(session = 1001L, width = 320, height = 240),
        ).assertSucceeded()
        harness.native.attachFailuresRemaining[1002L] = 1
        assertEquals(
            "vtk_create_failed",
            harness.call(
                method = "createView",
                arguments = viewArguments(session = 1002L, width = 640, height = 480),
            ).errorCode,
        )

        harness.close()

        assertEquals(harness.native.createdHandles, harness.native.destroyedHandles)
        assertTrue(harness.textures.all(FakeTexture::released))
        assertTrue(harness.executors.all(DirectSessionExecutor::shutDown))
    }

    @Test
    fun textureCleanupFailureIsReportedAndRetryableAfterNativeCleanup() {
        val harness = ControllerHarness()
        val textureId = harness.call(
            method = "createView",
            arguments = viewArguments(session = 1101L, width = 320, height = 240),
        ).successMap()["textureId"]
        val texture = harness.textures.single { it.id == textureId }
        texture.releaseFailuresRemaining = 1

        val firstDisposal = harness.call(
            method = "disposeView",
            arguments = mapOf("nativeSessionAddress" to 1101L),
        )

        assertEquals("vtk_dispose_failed", firstDisposal.errorCode)
        assertFalse(texture.released)
        assertEquals(1, harness.native.destroyedHandles.size)

        harness.call(
            method = "disposeView",
            arguments = mapOf("nativeSessionAddress" to 1101L),
        ).assertSucceeded()
        assertTrue(texture.released)
        assertEquals(1, harness.native.destroyedHandles.size)
    }
}

private class ControllerHarness(
    executorFactory: AndroidSessionExecutorFactory? = null,
) {
    val textures = mutableListOf<FakeTexture>()
    val native = FakeNativePresentation()
    val executors = mutableListOf<DirectSessionExecutor>()
    private var nextTextureId = 1L
    private val controller = AndroidSessionViewController(
        textureFactory = AndroidPresentationTextureFactory { viewport ->
            FakeTexture(id = nextTextureId++, size = viewport).also(textures::add)
        },
        native = native,
        executorFactory = executorFactory ?: AndroidSessionExecutorFactory {
            DirectSessionExecutor().also(executors::add)
        },
        dispatch = { completion -> completion() },
        onCloseFailure = { throw AssertionError("Unexpected close failure", it) },
    )

    fun call(method: String, arguments: Any?): RecordingResult = RecordingResult().also { result ->
        controller.onMethodCall(MethodCall(method, arguments), result)
    }

    fun close() {
        controller.close()
    }
}

private class FakeTexture(
    override val id: Long,
    var size: AndroidViewport,
) : AndroidPresentationTexture {
    override val surface: Surface? = null
    var released = false
    var releaseFailuresRemaining = 0
    private var frameListener: (() -> Unit)? = null

    override fun resize(viewport: AndroidViewport) {
        size = viewport
    }

    override fun setOnFrameConsumedListener(listener: () -> Unit) {
        frameListener = listener
    }

    override fun release() {
        if (releaseFailuresRemaining > 0) {
            releaseFailuresRemaining -= 1
            error("texture release failed for $id")
        }
        released = true
    }

    fun consumeFrame() {
        frameListener?.invoke()
    }
}

private class FakeNativePresentation : AndroidNativePresentation {
    override val available = true
    val createdHandles = mutableListOf<Long>()
    val destroyedHandles = mutableListOf<Long>()
    val resizedHandles = mutableListOf<Long>()
    val recreatedHandles = mutableListOf<Long>()
    val handleForSession = mutableMapOf<Long, Long>()
    val sessionForHandle = mutableMapOf<Long, Long>()
    val attachFailuresRemaining = mutableMapOf<Long, Int>()
    val destroyFailuresRemaining = mutableMapOf<Long, Int>()
    private var nextHandle = 1001L

    override fun create(
        presentationApiAddress: Long,
        nativeSessionAddress: Long,
        texture: AndroidPresentationTexture,
        viewport: AndroidViewport,
    ): Long {
        check(presentationApiAddress > 0L)
        check(texture.id > 0L)
        check(viewport.width > 0 && viewport.height > 0)
        return nextHandle++.also { handle ->
            createdHandles += handle
            handleForSession[nativeSessionAddress] = handle
            sessionForHandle[handle] = nativeSessionAddress
        }
    }

    override fun attach(handle: Long) {
        val session = sessionForHandle.getValue(handle)
        val remaining = attachFailuresRemaining[session] ?: 0
        if (remaining > 0) {
            attachFailuresRemaining[session] = remaining - 1
            error("attach failed for session $session")
        }
    }

    override fun resize(handle: Long, viewport: AndroidViewport) {
        check(viewport.width > 0 && viewport.height > 0)
        resizedHandles += handle
    }

    override fun recreateGraphicsContext(
        handle: Long,
        texture: AndroidPresentationTexture,
        viewport: AndroidViewport,
    ) {
        check(texture.id > 0L)
        check(viewport.width > 0 && viewport.height > 0)
        recreatedHandles += handle
    }

    override fun destroy(handle: Long) {
        val remaining = destroyFailuresRemaining[handle] ?: 0
        if (remaining > 0) {
            destroyFailuresRemaining[handle] = remaining - 1
            error("destroy failed for handle $handle")
        }
        destroyedHandles += handle
    }
}

private class DirectSessionExecutor : AndroidSessionExecutor {
    var shutDown = false

    override fun execute(operation: () -> Unit) {
        check(!shutDown)
        operation()
    }

    override fun shutdown() {
        shutDown = true
    }
}

private class QueuedSessionExecutor : AndroidSessionExecutor {
    private val operations = ArrayDeque<() -> Unit>()
    var shutDown = false

    override fun execute(operation: () -> Unit) {
        check(!shutDown)
        operations += operation
    }

    override fun shutdown() {
        shutDown = true
    }

    fun runNext() {
        operations.removeFirst().invoke()
    }
}

private class RecordingResult : MethodChannel.Result {
    var completed = false
    var value: Any? = null
    var errorCode: String? = null
    var errorMessage: String? = null

    override fun success(result: Any?) {
        check(!completed)
        completed = true
        value = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        check(!completed)
        completed = true
        this.errorCode = errorCode
        this.errorMessage = errorMessage
    }

    override fun notImplemented() {
        error("Unexpected notImplemented result")
    }

    fun assertSucceeded() {
        assertTrue(completed)
        assertNull(errorCode, errorMessage)
    }

    @Suppress("UNCHECKED_CAST")
    fun successMap(): Map<String, Any> {
        assertSucceeded()
        return value as Map<String, Any>
    }
}

private fun viewArguments(
    session: Long,
    width: Int,
    height: Int,
    presentationApi: Long = 4096L,
): Map<String, Any> = mapOf(
    "nativeSessionAddress" to session,
    "presentationApiAddress" to presentationApi,
    "width" to width,
    "height" to height,
)
