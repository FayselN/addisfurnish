import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/di/service_locator.dart';
import '../../../core/navigation/routes.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/format.dart';
import '../../../core/state/app_state.dart';
import '../../../core/state/app_state_mixin.dart';
import '../../../core/widgets/listing_grid.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/network/supabase_api.dart' show ListingFilters, SupabaseApi;
import '../../profile/domain/profile_repository.dart';
import '../domain/listing_query.dart';
import '../domain/listings_repository.dart';
import '../../sell/domain/listing_attributes.dart';

/// Full listing browser with search, filters and sorting (mirrors `/browse`).
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery, this.categorySlug});

  final String? initialQuery;
  final String? categorySlug;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with AppStateMixin {
  final _searchController = TextEditingController();
  ListingFilters _filters = const ListingFilters();
  List<Listing>? _listings;
  List<String>? _trending;
  List<Category>? _categories;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 0;
  String? _error;
  List<Map<String, dynamic>> _suggestions = const [];
  bool _suggestOpen = false;
  bool _filtersOpen = false;
  Timer? _suggestDebounce;
  Position? _location;
  bool _locating = false;

  ListingsRepository get _repo => sl<ListingsRepository>();
  ProfileRepository get _profileRepo => sl<ProfileRepository>();

  @override
  void initState() {
    super.initState();
    _filters = ListingFilters(category: widget.categorySlug, q: widget.initialQuery);
    _searchController.text = widget.initialQuery ?? '';
    _load();
    _loadAux();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _suggestDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadAux() async {
    try {
      final categories = await _repo.getCategories();
      final trending = await _repo.getTrendingSearches(limit: 8);
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _trending = trending;
      });
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadingMore = false;
      _page = 0;
      _hasMore = false;
      _error = null;
      _suggestOpen = false;
    });
    try {
      final results = await _repo.getListings(
        ListingQuery(filters: _filters, page: 0, limit: _filters.limit ?? 48),
      );
      if (!mounted) return;
      setState(() {
        _listings = _sortResults(results.items);
        _loading = false;
        _hasMore = results.hasMore;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final results = await _repo.getListings(
        ListingQuery(filters: _filters, page: _page + 1, limit: _filters.limit ?? 48),
      );
      if (!mounted) return;
      setState(() {
        _page += 1;
        _listings = _sortResults([...?_listings, ...results.items]);
        _hasMore = results.hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// "Nearest to me" is resolved client-side (mirrors RN): the query still
  /// fetches newest-first, then the loaded rows are re-ordered by distance
  /// from the user's location.
  List<Listing> _sortResults(List<Listing> items) {
    if (_filters.sort != 'nearest' || _location == null) return items;
    final list = [...items];
    list.sort((a, b) => _distanceKm(a).compareTo(_distanceKm(b)));
    return list;
  }

  double _distanceKm(Listing l) {
    final loc = _location;
    if (loc == null || l.latitude == null || l.longitude == null) return double.infinity;
    return _haversineKm(loc.latitude, loc.longitude, l.latitude!, l.longitude!);
  }

  /// Haversine distance in kilometres (matches RN `share/utils`).
  static double _haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371.0;
    final toRad = math.pi / 180;
    final dLat = (lat2 - lat1) * toRad;
    final dLon = (lon2 - lon1) * toRad;
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1 * toRad) * math.cos(lat2 * toRad) * math.pow(math.sin(dLon / 2), 2);
    return 2 * r * math.asin(math.sqrt(a.toDouble()));
  }

  Future<void> _locate() async {
    setState(() => _locating = true);
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppState.instance.t('locationDenied'))));
          }
          return;
        }
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      if (!mounted) return;
      setState(() {
        _location = pos;
        _filters = _filters.copyWith(sort: 'nearest');
      });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppState.instance.t('common.error'))));
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _onQueryChanged(String text) async {
    if (text.trim().length < 2) {
      _suggestDebounce?.cancel();
      if (!mounted) return;
      setState(() {
        _suggestions = const [];
        _suggestOpen = false;
      });
      return;
    }
    // Debounce network calls while the user is typing.
    _suggestDebounce?.cancel();
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      final results = await _repo.getSuggestions(text.trim(), limit: 6);
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _suggestOpen = true;
      });
    });
  }

  void _submitSearch(String q) {
    setState(() {
      _filters = _filters.copyWith(q: q);
      _suggestOpen = false;
      _searchController.text = q;
    });
    _repo.logSearch(q);
    _load();
  }

  Future<void> _saveSearch() async {
    final uid = AppState.instance.userId;
    if (uid == null) {
      _snack(AppState.instance.t('browse.signInToSaveSearch'));
      return;
    }
    await _profileRepo.saveSearch(
      uid,
      query: _filters.q,
      category: _filters.category,
      min: _filters.min,
      max: _filters.max,
    );
    _snack('${AppState.instance.t('browse.saveSearch')} ✓');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final listings = _listings ?? const <Listing>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(state.t('browse.title')),
        actions: [
          IconButton(
            onPressed: _openFilters,
            icon: const Icon(Icons.tune),
            tooltip: state.t('browse.filters'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onQueryChanged,
              onSubmitted: _submitSearch,
              decoration: InputDecoration(
                hintText: state.t('nav.search'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _filters = _filters.copyWith(q: null);
                            _suggestions = const [];
                            _suggestOpen = false;
                          });
                          _load();
                        },
                      )
                    : null,
              ),
            ),
          ),
          _buildSortChips(state),
          if (_suggestOpen && _suggestions.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  for (final s in _suggestions)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.history),
                      title: Text(s['title'] as String? ?? ''),
                      subtitle: Text('${s['city']} · ${Fmt.birr(s['price'])}'),
                      onTap: () {
                        final id = s['id'] as String;
                        Routes.listingById(context, id);
                        setState(() => _suggestOpen = false);
                      },
                    ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!),
                            const SizedBox(height: 12),
                            FilledButton(onPressed: _load, child: Text(state.t('common.retry'))),
                          ],
                        ),
                      )
                    : listings.isEmpty
                        ? _buildEmpty(state)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                                child: Row(
                                  children: [
                                    Text(
                                      state.t(
                                        'browse.itemsAvailable',
                                        {'count': listings.length},
                                      ),
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      onPressed: _saveSearch,
                                      icon: const Icon(Icons.bookmark_add_outlined),
                                      tooltip: state.t('browse.saveSearch'),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: ListingGrid(
                                  listings: listings,
                                  onListingTap: (l) => Routes.listing(context, l),
                                  onLoadMore: _loadMore,
                                  hasMore: _hasMore,
                                  loadingMore: _loadingMore,
                                ),
                              ),
                            ],
                          ),
          ),
        ],
      ),
      floatingActionButton: _filtersOpen
          ? FloatingActionButton(
              onPressed: () => setState(() {
                    _filtersOpen = false;
                    _filters = _filters.copyWith(clear: true);
                    _searchController.clear();
                  }),
              child: const Icon(Icons.filter_alt_off),
            )
          : null,
    );
  }

  Widget _buildSortChips(AppState state) {
    final sort = _filters.sort;
    final options = <({String? key, String label})>[
      (key: null, label: state.t('browse.newest')),
      (key: 'price-asc', label: state.t('browse.priceAsc')),
      (key: 'price-desc', label: state.t('browse.priceDesc')),
      (key: 'viewed', label: state.t('browse.mostViewed')),
      (key: 'nearest', label: state.t('browse.nearest')),
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final o = options[i];
          final selected = o.key == null ? sort == null : sort == o.key;
          return ChoiceChip(
            label: o.key == 'nearest' && _locating
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(o.label),
            selected: selected,
            onSelected: (_) => _onSortSelected(o.key),
          );
        },
      ),
    );
  }

  void _onSortSelected(String? key) {
    if (key == 'nearest') {
      _locate();
      return;
    }
    setState(() {
      _filters = ListingFilters(
        q: _filters.q,
        category: _filters.category,
        condition: _filters.condition,
        material: _filters.material,
        room: _filters.room,
        city: _filters.city,
        min: _filters.min,
        max: _filters.max,
        discounted: _filters.discounted,
        featured: _filters.featured,
        sort: key,
        sellerId: _filters.sellerId,
        limit: _filters.limit,
      );
    });
    _load();
  }

  Widget _buildEmpty(AppState state) {
    final trending = _trending ?? const <String>[];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        Icon(Icons.search_off, size: 48, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 12),
        Text(
          state.t('browse.emptyTitle'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          state.t('browse.emptyBody'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
        if (trending.isNotEmpty) ...[
          const SizedBox(height: 24),
          SectionHeader(title: state.t('home.popularSearches')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final q in trending)
                ActionChip(
                  label: Text(q),
                  onPressed: () => _submitSearch(q),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _openFilters() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => _FilterSheet(filters: _filters, categories: _categories)),
    );
    if (result == null || !mounted) return;
    final newSort = result['sort'] as String? ?? _filters.sort;
    setState(() {
      _filters = ListingFilters(
        q: _filters.q,
        category: result['category'] as String? ?? _filters.category,
        condition: result['condition'] as String?,
        city: result['city'] as String?,
        min: (result['min'] as num?)?.toDouble(),
        max: (result['max'] as num?)?.toDouble(),
        // "Nearest" needs a location; _locate() applies it only on success.
        sort: newSort == 'nearest' ? _filters.sort : newSort,
        discounted: result['discounted'] as bool? ?? false,
        attributes: (result['attributes'] as Map<String, List<Object>>?) ??
            _filters.attributes,
      );
    });
    if (newSort == 'nearest' && _location == null) {
      _locate();
      return;
    }
    _load();
  }
}

/// Full-screen filter picker for the browse screen.
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.filters, required this.categories});

  final ListingFilters filters;
  final List<Category>? categories;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  /// Selected category chain, narrowest last (slug chain: parent → … → leaf).
  /// Filtering by any level matches its whole subtree server-side, but the
  /// dynamic attribute controls always resolve against the deepest pick.
  List<String> _catSlugPath = const [];
  String get _selectedSlug => _catSlugPath.isEmpty ? '' : _catSlugPath.last;
  String? _condition;
  String? _city;
  String? _sort;
  double? _min;
  double? _max;
  bool _discounted = false;

  // Phase 6 (§14): dynamic attribute filters for the selected category.
  List<CategoryAttributeDef> _attrDefs = const [];
  final Map<String, String?> _attrSingle = {};
  final Map<String, Set<String>> _attrMulti = {};
  final Map<String, bool?> _attrBool = {};
  final Map<String, TextEditingController> _attrText = {};
  final Map<String, TextEditingController> _attrRangeMin = {};
  final Map<String, TextEditingController> _attrRangeMax = {};

  @override
  void initState() {
    super.initState();
    _catSlugPath = _slugPath(widget.filters.category);
    _condition = widget.filters.condition;
    _city = widget.filters.city;
    _sort = widget.filters.sort;
    _min = widget.filters.min;
    _max = widget.filters.max;
    _discounted = widget.filters.discounted;
    // Seed the dynamic selections from the active filters, then resolve the
    // category's attribute definitions.
    _seedAttrSelections(widget.filters.attributes ?? const {});
    _loadAttrDefs();
  }

  @override
  void dispose() {
    for (final c in _attrText.values) {
      c.dispose();
    }
    for (final c in _attrRangeMin.values) {
      c.dispose();
    }
    for (final c in _attrRangeMax.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Root → … → leaf slug chain for [slug]; empty for null or unknown slugs.
  List<String> _slugPath(String? slug) {
    final cats = widget.categories ?? const <Category>[];
    if (slug == null) return const [];
    Category? cur;
    for (final c in cats) {
      if (c.slug == slug) {
        cur = c;
        break;
      }
    }
    if (cur == null) return [slug];
    final path = <String>[cur.slug];
    while (true) {
      final parentId = cur!.parentId;
      final parent = cats.where((c) => c.id == parentId).toList();
      if (parentId == null || parent.isEmpty) break;
      cur = parent.first;
      path.insert(0, cur.slug);
    }
    return path;
  }

  /// Category id for the deepest selected slug.
  String? get _categoryId {
    final slug = _selectedSlug;
    if (slug.isEmpty) return null;
    for (final c in widget.categories ?? const <Category>[]) {
      if (c.slug == slug) return c.id;
    }
    return null;
  }

  /// Categories shown in the chip row for chain position [level]: the roots
  /// when [level] is 0, otherwise the children of the category selected one
  /// level above.
  List<Category> _catsAt(int level) {
    final cats = widget.categories ?? const <Category>[];
    String? parentId;
    if (level > 0) {
      final parentSlug = _catSlugPath[level - 1];
      for (final c in cats) {
        if (c.slug == parentSlug) {
          parentId = c.id;
          break;
        }
      }
    }
    return cats.where((c) => c.parentId == parentId).toList();
  }

  Future<void> _loadAttrDefs() async {
    final id = _categoryId;
    if (id == null) {
      if (mounted) setState(() => _attrDefs = const []);
      return;
    }
    try {
      final defs = await SupabaseApi.fetchCategoryAttributes(id);
      for (final d in defs) {
        if (d.type == 'text') {
          _attrText.putIfAbsent(d.attributeId, TextEditingController.new);
        } else if (d.type == 'number' || d.type == 'range') {
          _attrRangeMin.putIfAbsent(d.attributeId, TextEditingController.new);
          _attrRangeMax.putIfAbsent(d.attributeId, TextEditingController.new);
        } else if (d.type == 'single_select') {
          _attrSingle.putIfAbsent(d.attributeId, () => null);
        } else if (d.type == 'multi_select') {
          _attrMulti.putIfAbsent(d.attributeId, () => <String>{});
        } else if (d.type == 'boolean') {
          _attrBool.putIfAbsent(d.attributeId, () => null);
        }
      }
      if (!mounted) return;
      setState(() => _attrDefs = defs);
      _applySeeds(defs);
    } catch (_) {
      // Best-effort: without definitions the sheet just shows static filters.
    }
  }

  void _seedAttrSelections(Map<String, List<Object>> attrs) {
    // Values arrive keyed by SLUG; the definitions carry the ids, so seeding
    // happens once the definitions load (see _applySeeds).
    _pendingSeed = attrs;
  }

  Map<String, List<Object>>? _pendingSeed;

  void _applySeeds(List<CategoryAttributeDef> defs) {
    final seed = _pendingSeed;
    if (seed == null || seed.isEmpty) return;
    for (final def in defs) {
      final values = seed[def.slug];
      if (values == null || values.isEmpty) continue;
      switch (def.type) {
        case 'single_select':
          final opt = def.options.where((o) => values.contains(o.value)).toList();
          if (opt.isNotEmpty) _attrSingle[def.attributeId] = opt.first.id;
        case 'multi_select':
          _attrMulti[def.attributeId] = {
            for (final o in def.options)
              if (values.contains(o.value)) o.id,
          };
        case 'boolean':
          _attrBool[def.attributeId] = values.first == true || values.first == 'true';
        case 'number' || 'range':
          if (values.first is List) {
            final pair = values.first as List;
            _attrRangeMin[def.attributeId]?.text =
                pair[0] == null ? '' : (pair[0] as num).toString();
            _attrRangeMax[def.attributeId]?.text =
                pair[1] == null ? '' : (pair[1] as num).toString();
          }
        default: // text
          _attrText[def.attributeId]?.text = '${values.first}';
      }
    }
    _pendingSeed = null;
  }

  /// Build the attributes payload for the saved filters (spec §14 semantics:
  /// attributes AND, values within one attribute OR). Empty selections are
  /// omitted so they don't filter anything out.
  Map<String, List<Object>>? _collectAttributes() {
    final out = <String, List<Object>>{};
    for (final def in _attrDefs) {
      final id = def.attributeId;
      switch (def.type) {
        case 'single_select':
          final v = _attrSingle[id];
          if (v != null) {
            for (final o in def.options) {
              if (o.id == v) {
                out[def.slug] = [o.value];
                break;
              }
            }
          }
        case 'multi_select':
          final sel = _attrMulti[id] ?? const <String>{};
          final vals = [
            for (final o in def.options)
              if (sel.contains(o.id)) o.value,
          ];
          if (vals.isNotEmpty) out[def.slug] = vals;
        case 'boolean':
          // Unset (null) must not filter — defaulting to false would hide
          // listings whose boolean attribute is true.
          final v = _attrBool[id];
          if (v != null) out[def.slug] = [v];
        case 'number' || 'range':
          final lo = double.tryParse(_attrRangeMin[id]?.text ?? '');
          final hi = double.tryParse(_attrRangeMax[id]?.text ?? '');
          if (lo != null || hi != null) {
            out[def.slug] = [
              [lo, hi],
            ];
          }
        default: // text
          final t = _attrText[id]?.text.trim() ?? '';
          if (t.isNotEmpty) out[def.slug] = [t];
      }
    }
    return out.isEmpty ? null : out;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final minCtrl = TextEditingController(text: _min?.toStringAsFixed(0) ?? '');
    final maxCtrl = TextEditingController(text: _max?.toStringAsFixed(0) ?? '');

    return Scaffold(
      appBar: AppBar(title: Text(state.t('browse.filters'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _label(state.t('browse.sort')),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text(state.t('browse.newest')),
                selected: _sort == null,
                onSelected: (_) => setState(() => _sort = null),
              ),
              ChoiceChip(
                label: Text(state.t('browse.priceAsc')),
                selected: _sort == 'price-asc',
                onSelected: (_) => setState(() => _sort = 'price-asc'),
              ),
              ChoiceChip(
                label: Text(state.t('browse.priceDesc')),
                selected: _sort == 'price-desc',
                onSelected: (_) => setState(() => _sort = 'price-desc'),
              ),
              ChoiceChip(
                label: Text(state.t('browse.mostViewed')),
                selected: _sort == 'viewed',
                onSelected: (_) => setState(() => _sort = 'viewed'),
              ),
              ChoiceChip(
                label: Text(state.t('browse.nearest')),
                selected: _sort == 'nearest',
                onSelected: (_) => setState(() => _sort = 'nearest'),
              ),
            ],
          ),
          const SizedBox(height: 20),

          _label(state.t('browse.category')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(state.t('browse.allItems')),
                selected: _catSlugPath.isEmpty,
                onSelected: (_) {
                  setState(() => _catSlugPath = const []);
                  _loadAttrDefs();
                },
              ),
              // One chip row per level: pick a level to drill into its
              // children; the attribute section follows the deepest pick.
              for (int level = 0; level <= _catSlugPath.length; level++)
                for (final c in _catsAt(level))
                  ChoiceChip(
                    label: Text(
                      state.lang == 'am' && c.nameAm != null ? c.nameAm! : c.name,
                    ),
                    selected: level < _catSlugPath.length &&
                        _catSlugPath[level] == c.slug,
                    onSelected: (_) {
                      setState(() {
                        _catSlugPath = [..._catSlugPath.sublist(0, level), c.slug];
                      });
                      _loadAttrDefs();
                    },
                  ),
            ],
          ),
          const SizedBox(height: 20),

          _label(state.t('browse.condition')),
          Wrap(
            spacing: 8,
            children: [
              for (final cond in const ['like new', 'good', 'fair', 'poor'])
                ChoiceChip(
                  label: Text(state.t('browse.cond.$cond')),
                  selected: _condition == cond,
                  onSelected: (sel) => setState(() => _condition = sel ? cond : null),
                ),
            ],
          ),
          const SizedBox(height: 20),

          _label(state.t('browse.priceRange')),
          Row(
            children: [
              Expanded(child: TextField(controller: minCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: state.t('browse.min')))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: maxCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: state.t('browse.max')))),
            ],
          ),

          // Phase 6 (§14): dynamic attribute filters — only the attributes
          // the selected category configures appear, loaded live.
          if (_attrDefs.isNotEmpty) ...[
            const SizedBox(height: 20),
            for (final def in _attrDefs)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _attrField(state, def),
              ),
          ],

          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(state.t('browse.onlyDiscounted')),
            value: _discounted,
            onChanged: (v) => setState(() => _discounted = v),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.of(context).pop({
              'category': _catSlugPath.isEmpty ? null : _selectedSlug,
              'condition': _condition,
              'city': _city,
              'sort': _sort,
              'min': double.tryParse(minCtrl.text),
              'max': double.tryParse(maxCtrl.text),
              'discounted': _discounted,
              'attributes': _collectAttributes(),
            }),
            child: Text(state.t('common.save')),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  /// One dynamically-configured attribute filter control (spec §14). The
  /// control matches the attribute's type; selections live in the
  /// per-attribute maps that [_collectAttributes] reads on save.
  Widget _attrField(AppState state, CategoryAttributeDef def) {
    final theme = Theme.of(context);
    final id = def.attributeId;
    final label =
        '${state.lang == 'am' && def.nameAm != null ? def.nameAm! : def.name}'
        '${def.unit != null ? ' (${def.unit})' : ''}';

    switch (def.type) {
      case 'boolean':
        final v = _attrBool[id];
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(label),
          value: v ?? false,
          secondary: v == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: 'Any',
                  onPressed: () => setState(() => _attrBool[id] = null),
                ),
          // First toggle goes true→false→(reset via the clear icon to any).
          onChanged: (val) => setState(() => _attrBool[id] = val),
        );
      case 'single_select':
        return DropdownButtonFormField<String>(
          initialValue: _attrSingle[id],
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          hint: Text(label),
          items: [
            // Explicit "any" choice so a made selection can be cleared.
            const DropdownMenuItem(value: '__any__', child: Text('Any')),
            for (final o in def.options)
              DropdownMenuItem(
                value: o.id,
                child: Text(
                  state.lang == 'am' && o.labelAm != null ? o.labelAm! : o.label,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) =>
              setState(() => _attrSingle[id] = v == '__any__' ? null : v),
        );
      case 'multi_select':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in def.options)
                  FilterChip(
                    label: Text(
                      state.lang == 'am' && o.labelAm != null
                          ? o.labelAm!
                          : o.label,
                    ),
                    selected: _attrMulti[id]?.contains(o.id) ?? false,
                    onSelected: (sel) => setState(() {
                      final set = _attrMulti.putIfAbsent(id, () => <String>{});
                      sel ? set.add(o.id) : set.remove(o.id);
                    }),
                  ),
              ],
            ),
          ],
        );
      case 'number' || 'range':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _attrRangeMin[id],
                    keyboardType: TextInputType.number,
                    decoration:
                        InputDecoration(labelText: state.t('browse.min')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _attrRangeMax[id],
                    keyboardType: TextInputType.number,
                    decoration:
                        InputDecoration(labelText: state.t('browse.max')),
                  ),
                ),
              ],
            ),
          ],
        );
      default: // text
        return TextField(
          controller: _attrText[id],
          decoration: InputDecoration(labelText: label),
        );
    }
  }
}
