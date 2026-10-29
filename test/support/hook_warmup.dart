/// No-op entrypoint used only to trigger the Dart hooks link phase (see
/// `startProbeProcess` in dart_vm.dart): `dart run` on this file generates
/// `.dart_tool/native_assets.yaml` + `.dart_tool/lib/sqlite3.dll`, which
/// raw-`dart` probe children need to resolve sqlite3 3.x native assets.
void main() {}
