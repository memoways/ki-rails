require 'sprockets'

Sprockets.unregister_postprocessor 'application/javascript', Sprockets::SafetyColons
Sprockets.register_engine '.ki', Ki::Template

