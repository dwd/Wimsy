/// Builds the same-origin web handoff URL encoded into the Android export QR.
Uri buildAndroidLoginExportUri({
  required Uri webAppUri,
  required String jid,
  required String password,
  required String displayName,
}) {
  return Uri.parse(webAppUri.origin).replace(
    path: '/open-wimsy.html',
    queryParameters: {
      'jid': jid,
      'password': password,
      if (displayName.trim().isNotEmpty) 'display_name': displayName.trim(),
    },
  );
}
