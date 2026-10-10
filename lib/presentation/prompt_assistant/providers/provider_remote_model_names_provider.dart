import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Account-scoped catalog labels are ephemeral and refreshed after sign-in.
final providerRemoteModelNamesProvider =
    StateProvider<Map<String, Map<String, String>>>((ref) => const {});
