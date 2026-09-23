package com.vivekapps.ledger

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    /**
     * [LedgerPlugin] lives in the application module rather than in a separate
     * pub package, so the generated registrant knows nothing about it and it
     * has to be added by hand. Adding it to `flutterEngine.plugins` rather
     * than wiring the channels here is what gets it the `ActivityAware`
     * callbacks it needs to show the runtime permission dialog.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(LedgerPlugin())
    }
}
