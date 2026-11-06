import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/di/service_locator.dart';
import '../../../core/navigation/routes.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/image_url.dart';
import '../../../core/state/app_state.dart';
import '../../../core/state/app_state_mixin.dart';
import '../../../core/widgets/app_image.dart';
import '../../../core/widgets/listing_grid.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/network/supabase_api.dart' show ListingFilters;
import '../../favorites/domain/favorites_repository.dart';
import '../../messages/domain/messages_repository.dart';
import '../../sell/domain/listing_attributes.dart';
import '../../sell/domain/sell_repository.dart';
import '../domain/listing_query.dart';
import '../domain/listings_repository.dart';

/// Full listing detail: gallery, price, details, seller card, contact actions,
/// similar items.
class ListingDetailScreen extends StatefulWidget {
  const ListingDetailScreen({super.key, this.listing, this.listingId});

  final Listing? listing;
  final String? listingId;

  @override
  State<ListingDetailScreen> createState() => _ListingDetailScreenState();
}

class _ListingDetailScreenState extends State<ListingDetailScreen> with AppStateMixin {
  ListingsRepository get _repo => sl<ListingsRepository>();
  FavoritesRepository get _favRepo => sl<FavoritesRepository>();
  MessagesRepository get _messagesRepo => sl<MessagesRepository>();
  SellRepository get _sellRepo => sl<SellRepository>();

  Listing? _listing;
  List<Listing>? _similar;
  /// Dynamic attribute rows for this listing (spec §8–§11): lazily loaded so
  /// admin-configured attributes render without a release.
  List<(CategoryAttributeDef, ListingAttributeValue)>? _attrRows;
  bool _attrLoaded = false;
  Set<String> _favIds = {};
  Offer? _myOffer;
  int _page = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _listing = widget.listing;
    if (_listing != null) {
      _loading = false;
      _loadSimilar();
    } else if (widget.listingId != null) {
      _loadListing();
    }
    _loadFavorites();
    _loadMyOffer();
    _recordView();
  }

  Future<void> _loadMyOffer() async {
    final listing = _listing;
    final uid = AppState.instance.userId;
    if (listing == null || uid == null || uid == listing.sellerId) return;
    try {
      final offer = await _sellRepo.getMyOfferForListing(listing.id, uid);
      if (!mounted) return;
      setState(() => _myOffer = offer);
    } catch (_) {}
  }

  Future<void> _loadListing() async {
    setState(() => _loading = true);
    try {
      final listing = await _repo.getListing(widget.listingId!);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _loading = false;
        // A newly loaded listing's attribute rows must be re-resolved.
        _attrRows = null;
        _attrLoaded = false;
      });
      if (listing != null) {
        _loadSimilar();
        _loadMyOffer();
        _loadAttrRows();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadSimilar() async {
    final listing = _listing;
    if (listing == null) return;
    try {
      final similar = await _repo.getListings(
        ListingQuery(filters: ListingFilters(category: listing.category?.slug, limit: 10)),
      );
      if (!mounted) return;
      setState(() {
        _similar = similar.items.where((l) => l.id != listing.id).take(10).toList();
      });
    } catch (_) {}
  }

  /// Values + definitions for the dynamic attribute section; silently absent
  /// when the listing has no category, no values, or definition fetch fails.
  Future<void> _loadAttrRows() async {
    final listing = _listing;
    final categoryId = listing?.categoryId;
    if (listing == null || categoryId == null || _attrLoaded) return;
    _attrLoaded = true;
    try {
      final defs = await _sellRepo.fetchCategoryAttributes(categoryId);
      final byId = {
        for (final d in defs) d.attributeId: d,
      };
      final values = await _sellRepo.fetchListingAttributeValues(listing.id);
      if (!mounted) return;
      setState(() {
        _attrRows = [
          for (final v in values)
            if (byId[v.attributeId] != null) (byId[v.attributeId]!, v),
        ];
      });
    } catch (_) {
      // Best-effort: detail page renders fine without the section.
    }
  }

  /// One attribute as label → display value; when both fail to render as a
  /// human string the row is skipped rather than showing raw ids.
  (String, String)? _attrRowDisplay(AppState state, CategoryAttributeDef def,
      ListingAttributeValue v) {
    final lang = state.lang;
    String? value;
    if (v.optionId != null) {
      for (final o in def.options) {
        if (o.id == v.optionId) {
          value = lang == 'am' && o.labelAm != null ? o.labelAm! : o.label;
          break;
        }
      }
    } else if (v.valueBoolean != null) {
      value = v.valueBoolean! ? 'Yes' : 'No';
    } else if (v.valueNumber != null) {
      final n = v.valueNumber!;
      value = n == n.roundToDouble()
          ? n.toStringAsFixed(0)
          : n.toStringAsFixed(1);
    } else if (v.valueText != null && v.valueText!.isNotEmpty) {
      value = v.valueText;
    }
    if (value == null || value.isEmpty) return null;
    final label = lang == 'am' && def.nameAm != null ? def.nameAm! : def.name;
    return (
      def.unit == null ? label : '$label (${def.unit})',
      value,
    );
  }

  Widget _buildAttrSection(
      BuildContext context, AppState state, ThemeData theme, Listing listing) {
    if (listing.categoryId == null) return const SizedBox.shrink();
    if (!_attrLoaded) _loadAttrRows();
    final rows = _attrRows;
    if (rows == null) return const SizedBox.shrink();
    final display = [
      for (final (def, v) in rows) _attrRowDisplay(state, def, v),
    ].whereType<(String, String)>().toList();
    if (display.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          state.lang == 'am' ? 'ዝርዝሮች' : 'Specifications',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 14),
          child: Column(
            children: [
              for (final (label, value) in display)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 5,
                        child: Text(
                          label,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                      ),
                      Expanded(
                        flex: 7,
                        child: Text(
                          value,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _loadFavorites() async {
    final uid = AppState.instance.userId;
    if (uid == null) return;
    try {
      final ids = await _favRepo.getFavoriteIds(uid);
      if (!mounted) return;
      setState(() {
        _favIds = ids.toSet();
      });
    } catch (_) {}
  }

  void _recordView() {
    final id = widget.listing?.id ?? widget.listingId;
    if (id != null) _repo.recordView(id);
  }

  Future<void> _toggleFavorite() async {
    final listing = _listing;
    final uid = AppState.instance.userId;
    if (listing == null) return;
    if (uid == null) {
      _requireSignIn();
      return;
    }
    final isFav = _favIds.contains(listing.id);
    try {
      await _favRepo.toggle(uid, listing.id, isFav);
      setState(() {
        if (isFav) {
          _favIds.remove(listing.id);
        } else {
          _favIds.add(listing.id);
        }
      });
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _contactSeller() async {
    final listing = _listing;
    final state = AppState.instance;
    if (listing == null || listing.seller == null) return;
    if (listing.isSold) {
      _snack(state.t('listing.soldMessage'));
      return;
    }
    if (!state.isSignedIn) {
      _requireSignIn();
      return;
    }
    final uid = state.userId!;
    if (uid == listing.sellerId) {
      _snack('This is your own listing');
      return;
    }
    final convId = await _messagesRepo.ensureConversation(listing.id, uid, listing.sellerId);
    if (!mounted) return;
    Routes.chat(
      context,
      conversationId: convId,
      otherName: listing.seller!.displayName,
      listingTitle: listing.title,
    );
  }

  Future<void> _callSeller() async {
    if (_listing?.isSold == true) {
      _snack(AppState.instance.t('listing.soldMessage'));
      return;
    }
    final phone = _listing?.seller?.phone;
    if (phone == null) return;
    await _launch('tel:$phone');
  }

  Future<void> _openWhatsApp() async {
    if (_listing?.isSold == true) {
      _snack(AppState.instance.t('listing.soldMessage'));
      return;
    }
    final wa = _listing?.seller?.whatsapp;
    if (wa == null) return;
    final digits = wa.replaceAll(RegExp(r'[^0-9]'), '');
    await _launch('https://wa.me/$digits');
  }

  Future<void> _openTelegram() async {
    if (_listing?.isSold == true) {
      _snack(AppState.instance.t('listing.soldMessage'));
      return;
    }
    final tg = _listing?.seller?.telegram;
    if (tg == null) return;
    await _launch('https://t.me/${tg.replaceAll('@', '')}');
  }

  Future<void> _requestCallback() async {
    final listing = _listing;
    final state = AppState.instance;
    if (listing == null || listing.seller == null) return;
    if (listing.isSold) {
      _snack(state.t('listing.soldMessage'));
      return;
    }
    if (!state.isSignedIn) {
      _requireSignIn();
      return;
    }
    final uid = state.userId!;
    if (uid == listing.sellerId) {
      _snack('This is your own listing');
      return;
    }
    final phone = state.profile?.phone ?? '';
    final formKey = GlobalKey<FormState>();
    final phoneCtrl = TextEditingController(text: phone);
    final noteCtrl = TextEditingController();
    final sent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(state.t('listing.callback')),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone number'),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Enter your phone number'
                      : null,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    hintText: 'e.g. available after 6pm',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(state.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(context, true);
            },
            child: Text('Send'),
          ),
        ],
      ),
    );
    if (sent != true) return;
    try {
      await _sellRepo.requestCallback(
        listingId: listing.id,
        buyerId: uid,
        sellerId: listing.seller!.id,
        listingTitle: listing.title,
        phone: phoneCtrl.text.trim(),
        note: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
      );
      if (mounted) _snack('${state.t('listing.callbackSent')} ✓');
    } catch (e) {
      if (mounted) _snack('$e');
    }
  }

  Future<void> _makeOffer() async {
    final listing = _listing;
    final state = AppState.instance;
    if (listing == null || listing.seller == null) return;
    if (listing.isSold) {
      _snack(state.t('listing.soldMessage'));
      return;
    }
    if (!state.isSignedIn) {
      _requireSignIn();
      return;
    }
    final uid = state.userId!;
    if (uid == listing.sellerId) {
      _snack(state.t('offer.cantOfferSelf'));
      return;
    }
    final amountCtrl = TextEditingController(text: listing.price.round().toString());
    final messageCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final sent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(state.t('listing.makeOffer')),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: amountCtrl,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: state.t('offer.amount'),
                    prefixText: 'ETB ',
                  ),
                  validator: (v) {
                    final n = double.tryParse(v ?? '');
                    if (n == null || n <= 0) return 'Enter a valid amount';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: messageCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: state.t('offer.message'),
                    hintText: 'e.g. I can pay cash today',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(state.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(context, true);
            },
            child: Text(state.t('offer.submit')),
          ),
        ],
      ),
    );
    if (sent != true) return;
    try {
      await _sellRepo.makeOffer(
        listingId: listing.id,
        buyerId: uid,
        sellerId: listing.seller!.id,
        amount: double.parse(amountCtrl.text.trim()),
        message: messageCtrl.text.trim().isEmpty ? null : messageCtrl.text.trim(),
      );
      if (mounted) {
        _snack('${state.t('offer.sent')} ✓');
        _loadMyOffer();
      }
    } catch (e) {
      if (mounted) _snack('$e');
    }
  }

  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) _snack('Could not open');
  }

  Future<void> _share() async {
    final listing = _listing;
    if (listing == null) return;
    await Share.share(
      '${listing.title}\n${Fmt.birr(listing.price)}\n'
      'Check it out on AddisHome!',
    );
  }

  Future<void> _report() async {
    final listing = _listing;
    final uid = AppState.instance.userId;
    if (listing == null) return;
    if (uid == null) {
      _requireSignIn();
      return;
    }
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${AppState.instance.t('listing.report')} · ${listing.title}'),
        children: [
          for (final r in const ['Suspected scam', 'Misleading photos or description', 'Item unavailable', 'Offensive or abusive'])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, r),
              child: Text(r),
            ),
        ],
      ),
    );
    if (reason == null) return;
    await _sellRepo.submitReport(
      reporterId: uid,
      reason: reason,
      listingId: listing.id,
      reportedUserId: listing.sellerId,
    );
    _snack('Report sent ✓');
  }

  void _requireSignIn() {
    _snack('Please sign in first');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final theme = Theme.of(context);
    final listing = _listing;

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (listing != null)
            IconButton(
              onPressed: _share,
              icon: const Icon(Icons.share_outlined),
              tooltip: state.t('listing.share'),
            ),
          if (listing != null)
            IconButton(
              onPressed: _report,
              icon: const Icon(Icons.flag_outlined),
              tooltip: state.t('listing.report'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? EmptyState(
                  icon: Icons.search_off,
                  title: state.t('listing.notFoundTitle'),
                  body: state.t('listing.notFoundBody'),
                  actionLabel: state.t('browse.allItems'),
                  onAction: () => Navigator.of(context).pop(),
                )
              : listing == null
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: state.t('listing.notFoundTitle'),
                      body: state.t('listing.notFoundBody'),
                    )
                  : _buildContent(context, state, theme, listing),
      bottomNavigationBar:
                  _listing == null || _listing!.isSold
                      ? null
                      : _contactBar(context, state, _listing!),
    );
  }

  Widget _contactBar(BuildContext context, AppState state, Listing listing) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed: _contactSeller,
          icon: const Icon(Icons.chat_bubble_outline),
          label: Text(state.t('listing.contact')),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, AppState state, ThemeData theme, Listing listing) {
    final isFav = _favIds.contains(listing.id);

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        // Gallery
        SizedBox(
          height: 300,
          child: Stack(
            children: [
              if (listing.images.isEmpty)
                AppImage(null, width: double.infinity, height: 300)
              else
                PageView.builder(
                  itemCount: listing.images.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, i) => AppImage(
                    listing.images[i].url,
                    width: double.infinity,
                    height: 300,
                    targetWidth: kLargeWidth,
                  ),
                ),
              if (listing.status != 'active') ...[
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: listing.isSold ? Colors.black54 : Colors.amber.shade800,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          listing.isSold ? Icons.sell : Icons.schedule,
                          size: 14,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          state.t(listing.isSold ? 'listing.statusSold' : 'listing.statusReserved'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (listing.images.length > 1)
                Positioned(
                  bottom: 12,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (int i = 0; i < listing.images.length; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: i == _page ? 18 : 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: i == _page
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(listing.title, style: theme.textTheme.headlineMedium),
                  ),
                  IconButton(
                    onPressed: _toggleFavorite,
                    icon: Icon(
                      isFav ? Icons.favorite : Icons.favorite_border,
                      color: isFav ? theme.colorScheme.error : theme.colorScheme.outline,
                    ),
                    tooltip: state.t('tabs.favorites'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    Fmt.birr(listing.price),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (listing.discountActive)
                    Text(
                      Fmt.birr(listing.originalPrice),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.outline,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                  if (listing.negotiable)
                    Chip(
                      label: Text(state.t('listing.negotiable')),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                state.t('listing.views', {'count': listing.viewCount}),
                style: theme.textTheme.bodySmall,
              ),

              const SizedBox(height: 20),
              _buildSellerCard(context, state, theme, listing),
              const SizedBox(height: 12),
              _buildContactActions(context, state, theme, listing),
              const SizedBox(height: 20),

              _featureGrid(state, theme, listing),
              const SizedBox(height: 20),

              _buildAttrSection(context, state, theme, listing),
              const SizedBox(height: 8),

              Text(state.t('listing.description'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(listing.description, style: theme.textTheme.bodyLarge),

              const SizedBox(height: 12),
              Text(
                state.t('listing.posted', {
                  'time': Fmt.ethiopianDate(listing.createdAt),
                }),
                style: theme.textTheme.bodySmall,
              ),

              const SizedBox(height: 20),
              // Delivery info
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.local_shipping_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        listing.deliveryOffered
                            ? (listing.deliveryFee != null && listing.deliveryFee! > 0
                                ? state.t('listing.deliveryAvailable', {'fee': Fmt.birr(listing.deliveryFee)})
                                : state.t('listing.deliveryFree'))
                            : state.t('listing.pickupOnly'),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),

              if (_similar?.isNotEmpty == true) ...[
                const SizedBox(height: 24),
                SectionHeader(title: state.t('listing.similar')),
                const SizedBox(height: 8),
                ListingRow(
                  listings: _similar!,
                  onListingTap: (l) => Routes.listing(context, l),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSellerCard(
      BuildContext context, AppState state, ThemeData theme, Listing listing) {
    final seller = listing.seller;
    return InkWell(
      onTap: () {
        if (seller?.shopSlug != null) Routes.shop(context, seller!.shopSlug!);
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            ClipOval(
              child: AppImage(
                seller?.photoUrl,
                width: 48,
                height: 48,
                icon: Icons.storefront_outlined,
                targetWidth: 144,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          seller?.displayName ?? state.t('listing.seller'),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (seller?.verified == true) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.verified, size: 16, color: theme.colorScheme.primary),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    seller?.isOnline == true
                        ? state.t('listing.onlineNow')
                        : state.t('listing.activeAgo', {
                            'time': Fmt.timeAgoShort(
                              DateTime.tryParse(seller?.lastSeen ?? '') ?? DateTime.now(),
                            ),
                          }),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: seller?.isOnline == true
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                  ),
                  if (seller?.city != null)
                    Text(seller!.city!, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }

  Widget _buildContactActions(
      BuildContext context, AppState state, ThemeData theme, Listing listing) {
    final seller = listing.seller;
    if (seller == null) return const SizedBox.shrink();

    if (listing.isSold) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(Icons.block, color: theme.colorScheme.outline),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                state.t('listing.soldMessage'),
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ],
        ),
      );
    }

    final isMine = state.userId == listing.sellerId;
    final actions = <Widget>[
      if (!isMine)
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _contactSeller,
            icon: const Icon(Icons.chat_bubble_outline, size: 18),
            label: Text(state.t('listing.contact'), textAlign: TextAlign.center),
          ),
        ),
      if (seller.phone != null)
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _callSeller,
            icon: const Icon(Icons.call_outlined, size: 18),
            label: Text(state.t('listing.call')),
          ),
        ),
      if (seller.whatsapp != null)
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _openWhatsApp,
            icon: const Icon(Icons.chat_outlined, size: 18),
            label: Text(state.t('listing.whatsapp')),
          ),
        ),
      if (seller.telegram != null)
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _openTelegram,
            icon: const Icon(Icons.send_outlined, size: 18),
            label: Text(state.t('listing.telegram')),
          ),
        ),
    ];

    return Column(
      children: [
        if (listing.isReserved) ...[
          _statusNotice(context, state, theme, listing),
          const SizedBox(height: 10),
        ],
        Row(children: actions.take(2).toList()),
        if (actions.length > 2) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              for (final a in actions.skip(2)) Expanded(child: a),
            ],
          ),
        ],
        if (!isMine) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: listing.isReserved ? null : _requestCallback,
              icon: const Icon(Icons.phone_callback_outlined, size: 18),
              label: Text(state.t('listing.callback')),
            ),
          ),
          if (_myOffer != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: _offerStatusChip(context, state, _myOffer!),
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: listing.isReserved ? null : _makeOffer,
            icon: const Icon(Icons.handshake_outlined, size: 18),
            label: Text(state.t('listing.makeOffer')),
          ),
        ],
      ],
    );
  }

  Widget _statusNotice(BuildContext context, AppState state, ThemeData theme, Listing listing) {
    final color = Colors.amber.shade700;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              state.t('listing.reservedNotice'),
              style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _offerStatusChip(BuildContext context, AppState state, Offer offer) {
    final theme = Theme.of(context);
    final statusKey = switch (offer.status) {
      'accepted' => 'offer.accepted',
      'declined' => 'offer.declined',
      'cancelled' => 'offer.cancelled',
      _ => 'offer.pending',
    };
    final color = offer.isPending
        ? Colors.amber.shade700
        : offer.status == 'accepted'
            ? theme.colorScheme.primary
            : theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.handshake, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            '${state.t('listing.offered')}: ${Fmt.birr(offer.amount)} · ${state.t(statusKey)}',
            style: theme.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _featureGrid(AppState state, ThemeData theme, Listing listing) {
    final features = <(IconData, String, String)>[
      (Icons.verified_outlined, state.t('listing.condition'), listing.condition),
      if (listing.material != null)
        (Icons.construction_outlined, state.t('listing.material'), listing.material!),
      if (listing.roomType != null)
        (Icons.meeting_room_outlined, state.t('listing.room'), listing.roomType!),
      if (listing.color != null)
        (Icons.palette_outlined, state.t('listing.color'), listing.color!),
      if (listing.brand != null)
        (Icons.label_outline, state.t('listing.brand'), listing.brand!),
      if (listing.category != null)
        (Icons.category_outlined, state.t('listing.category'), listing.category!.name),
      (Icons.location_on_outlined, state.t('sell.city'), listing.city),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (icon, label, value) in features)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Flexible(child: Text('$label: $value', style: theme.textTheme.labelMedium)),
              ],
            ),
          ),
      ],
    );
  }
}
