import 'package:timezone/timezone.dart';

class TimeZoneSettings {
  TimeZoneSettings({this.timezone});

  factory TimeZoneSettings.fromString(final String string) {
    // The app ships the reduced `timezone/data/latest.dart` dataset (no Etc/*
    // zones, no bare aliases), so a server-supplied zone like "Etc/UTC" is absent
    // and `locations[string]!` used to throw a null-check crash on every settings
    // refresh — leaving the authenticated UI stuck on loading placeholders. Fall
    // back to null (rendered as "Unknown") instead of crashing.
    final Location? location = timeZoneDatabase.locations[string];
    return TimeZoneSettings(timezone: location);
  }
  final Location? timezone;

  Map<String, dynamic> toJson() => {'timezone': timezone?.name ?? 'Unknown'};

  @override
  String toString() => timezone?.name ?? 'Unknown';
}
