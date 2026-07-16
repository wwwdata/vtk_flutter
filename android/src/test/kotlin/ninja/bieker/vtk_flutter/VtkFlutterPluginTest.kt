package ninja.bieker.vtk_flutter

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

internal class VtkFlutterPluginTest {
    @Test
    fun pluginCanBeConstructed() {
        assertNotNull(VtkFlutterPlugin())
    }

    @Test
    fun coreApiAddressMustBePositive() {
        assertEquals(4096L, readCoreApiAddress(mapOf("coreApiAddress" to 4096L)))
        assertNull(readCoreApiAddress(mapOf("coreApiAddress" to 0L)))
        assertNull(readCoreApiAddress(mapOf("coreApiAddress" to -1L)))
        assertNull(readCoreApiAddress(mapOf("coreApiAddress" to 4096.0)))
        assertNull(readCoreApiAddress(emptyMap<String, Any>()))
    }
}
