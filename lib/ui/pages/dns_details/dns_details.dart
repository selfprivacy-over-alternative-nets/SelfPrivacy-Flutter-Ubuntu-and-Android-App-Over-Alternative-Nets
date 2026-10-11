import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:selfprivacy/config/get_it_config.dart';
import 'package:selfprivacy/logic/api_maps/rest_maps/dns_providers/desired_dns_record.dart';
import 'package:selfprivacy/logic/cubit/dns_records/dns_records_cubit.dart';
import 'package:selfprivacy/logic/cubit/server_installation/server_installation_cubit.dart';
import 'package:selfprivacy/logic/get_it/resources_model.dart';
import 'package:selfprivacy/ui/atoms/icons/brand_icons.dart';
import 'package:selfprivacy/ui/atoms/list_tiles/section_headline.dart';
import 'package:selfprivacy/ui/layouts/brand_hero_screen.dart';
import 'package:selfprivacy/ui/molecules/cards/dns_state_card.dart';
import 'package:selfprivacy/ui/molecules/list_items/dns_record_item.dart';
import 'package:selfprivacy/utils/fake_data.dart';
import 'package:skeletonizer/skeletonizer.dart';

@RoutePage()
class DnsDetailsPage extends StatefulWidget {
  const DnsDetailsPage({super.key});

  @override
  State<DnsDetailsPage> createState() => _DnsDetailsPageState();
}

class _DnsDetailsPageState extends State<DnsDetailsPage> {
  @override
  Widget build(final BuildContext context) {
    final bool isReady =
        context.watch<ServerInstallationCubit>().state
            is ServerInstallationFinished;
    final String domain =
        getIt<ResourcesModel>().serverDomain?.domainName ?? '';
    final DnsRecordsState dnsCubit = context.watch<DnsRecordsCubit>().state;
    final List<DesiredDnsRecord> dnsRecords =
        context.watch<DnsRecordsCubit>().state.dnsRecords;

    if (!isReady) {
      return BrandHeroScreen(
        hasBackButton: true,
        heroIcon: BrandIcons.globe,
        heroTitle: 'domain.screen_title'.tr(),
        heroSubtitle: 'not_ready_card.in_menu'.tr(),
        children: const [],
      );
    }

    // 'refreshing' (→ skeleton) must track the LOADING STATE, not emptiness: a genuinely
    // empty result (provider NONE / a tunnel, where requiredDnsRecords is []) is 'good'
    // and must render as empty — not skeleton forever (req 161).
    final refreshing =
        dnsCubit.dnsState == DnsRecordsStatus.refreshing ||
        dnsCubit.dnsState == DnsRecordsStatus.uninitialized;
    final recordsToShow =
        refreshing ? FakeSelfPrivacyData.desiredDnsRecords : dnsRecords;
    // Loaded AND genuinely empty (provider NONE / a tunnel): show an explicit
    // "no records needed" message naming the setup, instead of empty headings (req 161).
    final bool noRecords = !refreshing && dnsRecords.isEmpty;

    List<Widget> recordsSection(
      final String title,
      final String subtitle,
      final DnsRecordsCategory category,
    ) => [
      SectionHeadline(title: title, subtitle: subtitle),
      ...recordsToShow
          .where((final dnsRecord) => dnsRecord.category == category)
          .map(
            (final dnsRecord) => Skeletonizer(
              enabled: refreshing,
              enableSwitchAnimation: true,
              child: DnsRecordItem(
                dnsRecord: dnsRecord,
                refreshing: refreshing,
              ),
            ),
          ),
    ];

    return BrandHeroScreen(
      hasBackButton: true,
      heroSubtitle: domain,
      heroIcon: BrandIcons.globe,
      heroTitle: 'domain.screen_title'.tr(),
      children: <Widget>[
        DnsStateCard(
          dnsState: dnsCubit.dnsState,
          fixCallback: () async {
            await context.read<DnsRecordsCubit>().fix();
          },
        ),
        const Gap(8),
        if (noRecords)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'domain.no_records_needed'.tr(
                namedArgs: {'setup': _setupLabel(domain)},
              ),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          )
        else ...<Widget>[
          ...recordsSection(
            'domain.services_title'.tr(),
            'domain.services_subtitle'.tr(),
            DnsRecordsCategory.services,
          ),
          const Gap(8),
          ...recordsSection(
            'domain.email_title'.tr(),
            'domain.email_subtitle'.tr(),
            DnsRecordsCategory.email,
          ),
          const Gap(8),
          ...recordsSection(
            'domain.other_title'.tr(),
            'domain.other_subtitle'.tr(),
            DnsRecordsCategory.other,
          ),
        ],
      ],
    );
  }
}

/// Human label for the reachability setup, derived from the public domain, so the
/// "no DNS records needed" message names WHY there is nothing to configure (req 161).
/// A single-hostname tunnel (provider NONE) has no DNS records to manage.
String _setupLabel(final String domain) {
  final String d = domain.toLowerCase();
  if (d.endsWith('.ts.net')) {
    return 'a Tailscale Funnel tunnel';
  }
  if (d.endsWith('.trycloudflare.com')) {
    return 'a Cloudflare quick tunnel';
  }
  if (d.endsWith('.ngrok-free.app') ||
      d.endsWith('.ngrok.app') ||
      d.endsWith('.ngrok.io')) {
    return 'an ngrok tunnel';
  }
  if (d.endsWith('.loca.lt')) {
    return 'a LocalTunnel tunnel';
  }
  if (d.endsWith('.pinggy.link')) {
    return 'a Pinggy tunnel';
  }
  if (d.endsWith('.onion')) {
    return 'a Tor hidden service';
  }
  return 'a tunnel (no DNS provider to manage)';
}
