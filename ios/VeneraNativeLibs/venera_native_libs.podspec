Pod::Spec.new do |s|
  s.name             = 'venera_native_libs'
  s.version          = '0.1.0'
  s.summary          = 'Prebuilt venera Rust static libraries.'
  s.description      = 'Device static libraries for the hand-rolled venera crates (inpaint, ocr_preprocess, jpg_encode, image_transpose, anime4k). Built by .github/scripts/build_venera_native.py ios into this directory before flutter build ios.'
  s.homepage         = 'https://github.com/ACGNnsj/venera-unified'
  s.license          = { :type => 'GPL-3.0-only' }
  s.author           = { 'Venera' => 'https://github.com/ACGNnsj/venera-unified' }
  s.source           = { :path => '.' }
  # No sources to compile: the .a files below are linked into Runner and
  # resolved at runtime via DynamicLibrary.process().
  s.source_files = 'dummy.c'
  s.vendored_libraries = 'libvenera_inpaint.a', 'libvenera_ocr_preprocess.a', 'libvenera_jpg_encode.a', 'libvenera_transpose.a', 'libvenera_anime4k.a'
  s.platform = :ios, '16.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
