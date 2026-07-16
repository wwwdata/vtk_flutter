package ninja.bieker.vtk_flutter

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** VtkFlutterPlugin */
class VtkFlutterPlugin : FlutterPlugin {
    private var adapter: AndroidVtkTextureAdapter? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        adapter = AndroidVtkTextureAdapter(
            messenger = flutterPluginBinding.binaryMessenger,
            textures = flutterPluginBinding.textureRegistry,
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        adapter?.close()
        adapter = null
    }
}
