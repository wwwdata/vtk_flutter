package ninja.bieker.vtk_flutter

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class VtkFlutterPluginTest {
    @Test
    fun pluginCanBeConstructed() {
        assertNotNull(VtkFlutterPlugin())
    }

    @Test
    fun presentationApiAddressMustBeAPositiveInteger() {
        assertEquals(
            4096L,
            readPresentationApiAddress(mapOf("presentationApiAddress" to 4096L)),
        )
        assertNull(readPresentationApiAddress(mapOf("presentationApiAddress" to 0L)))
        assertNull(readPresentationApiAddress(mapOf("presentationApiAddress" to -1L)))
        assertNull(readPresentationApiAddress(mapOf("presentationApiAddress" to 4096.0)))
        assertNull(readPresentationApiAddress(emptyMap<String, Any>()))
    }

    @Test
    fun nativeSessionAddressMustBeAPositiveInteger() {
        assertEquals(
            8192L,
            readNativeSessionAddress(mapOf("nativeSessionAddress" to 8192L)),
        )
        assertNull(readNativeSessionAddress(mapOf("nativeSessionAddress" to 0L)))
        assertNull(readNativeSessionAddress(mapOf("nativeSessionAddress" to -1L)))
        assertNull(readNativeSessionAddress(mapOf("nativeSessionAddress" to 8192.0)))
        assertNull(readNativeSessionAddress(emptyMap<String, Any>()))
    }

    @Test
    fun viewCreationReturnsOnlyTheFlutterTextureId() {
        assertEquals(mapOf("textureId" to 73L), viewResult(textureId = 73L))
    }

    @Test
    fun capabilitiesDescribeTheGenericAndroidPresentationBackend() {
        val capabilities = androidCapabilities(available = true)

        assertEquals("android", capabilities["backend"])
        assertEquals(1, capabilities["version"])
        assertEquals(256 * 1024 * 1024, capabilities["maxUploadBytes"])
        assertTrue(capabilities["supportsExternalTexture"] as Boolean)
        assertFalse(capabilities.containsKey("renderModes"))
    }

    @Test
    fun unavailableBackendReportsNoUploadOrExternalTextureSupport() {
        val capabilities = androidCapabilities(available = false)

        assertEquals(0, capabilities["maxUploadBytes"])
        assertFalse(capabilities["supportsExternalTexture"] as Boolean)
        assertFalse(capabilities.containsKey("renderModes"))
    }
}
