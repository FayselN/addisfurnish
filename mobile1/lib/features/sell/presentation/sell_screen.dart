import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:video_player/video_player.dart';

import '../../../core/di/service_locator.dart';
import '../../../core/models/models.dart';
import '../../../core/network/supabase_api.dart';
import '../../../core/state/app_state.dart';
import '../../../core/state/app_state_mixin.dart';
import '../../../core/utils/image_url.dart';
import '../../../core/widgets/calendar_picker.dart';
import '../../../core/widgets/draggable_pin_map.dart';
import '../../../core/widgets/section_header.dart';
import '../../listings/domain/listings_repository.dart';
import '../../profile/domain/profile_repository.dart';
import '../domain/listing_attributes.dart';
import '../domain/sell_repository.dart';

/// A listing photo shown in the form. In edit mode existing photos keep their
/// stored URL and are not re-uploaded; `[_SellImage.file]` is only set for
/// newly picked images.
class _SellImage {
  const _SellImage({this.file, this.url, required this.isExisting});

  final XFile? file;
  final String? url;
  final bool isExisting;
}

/// Where a listing photo should come from: freshly taken with the camera or
/// picked from the device gallery.
enum _ImageSource { camera, gallery }

/// Longest edge, in pixels, of an uploaded listing photo.
///
/// A phone camera hands back 4000x3000 at 3-5 MB. Uploading that untouched
/// costs the seller their data allowance, and every viewer then downloads it
/// again: the bucket serves the original, so a feed of a dozen such photos is
/// tens of megabytes. 1600px still fills a zoomed lightbox on any phone and
/// lands around 300 KB.
const int _kPhotoMaxEdge = 1600;

/// JPEG quality for uploaded photos. 82 is visually indistinguishable from the
/// original on furniture photography and roughly halves the bytes again.
const int _kPhotoQuality = 82;

/// Post-a-listing flow. If the user has not set up a shop yet, prompts them
/// to fill shop name and slug inline to start selling. When [editListingId] is
/// given the screen loads the existing listing and updates it instead of
/// creating a new one.
class SellScreen extends StatefulWidget {
  const SellScreen({super.key, this.profile, this.editListingId});

  final Profile? profile;
  final String? editListingId;

  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> with AppStateMixin {
  SellRepository get _repo => sl<SellRepository>();
  ListingsRepository get _listingsRepo => sl<ListingsRepository>();

  final _title = TextEditingController();
  final _description = TextEditingController();
  final _price = TextEditingController();
  final _originalPrice = TextEditingController();
  final _subCity = TextEditingController();
  final _deliveryFee = TextEditingController();

  /// Cities offered in the sell form's city dropdown.
  static const _cities = [
    'Addis Ababa',
    'Adama',
    'Bahir Dar',
    'Hawassa',
    'Mekelle',
    'Dire Dawa',
    'Gondar',
  ];

  String? _cityDropdown = 'Addis Ababa';
  /// Selected sub-city when the city is Addis Ababa (dropdown mode).
  String? _subCityValue;

  // Shop setup controller
  final _shopNameCtrl = TextEditingController();

  bool _negotiable = true;
  bool _delivery = false;
  String? _condition = 'good';
  /// Selected category chain, narrowest last (root → … → leaf). Full-depth,
  /// so dynamic attributes resolve against the most specific category.
  List<String> _catPath = const [];
  String? get _categoryId => _catPath.isEmpty ? null : _catPath.last;
  List<Category> _categories = const [];
  List<_SellImage> _images = const [];
  String? _discountDate;
  XFile? _video;
  String? _videoUrl;
  bool _videoExisting = false;
  LatLng? _location;
  bool _editing = false;
  bool _loadingEdit = false;
  bool _busy = false;
  bool _uploaded = false;

  // Dynamic category attributes (spec §15): definitions load live for the
  // selected category; the maps hold the seller's current selections.
  List<CategoryAttributeDef> _attrDefs = const [];
  List<ListingAttributeValue> _existingAttrValues = const [];
  final Map<String, TextEditingController> _attrText = {};
  final Map<String, String?> _attrSingle = {};
  final Map<String, Set<String>> _attrMulti = {};
  final Map<String, bool> _attrBool = {};

  static const _conditions = ['like new', 'good', 'fair', 'poor'];

  /// Bridge between the sticky condition chips and the Condition attribute
  /// (required, single_select) in categories that configure one: the chips set
  /// the corresponding attribute option so publishing doesn't fail with an
  /// inconsistent pair, and picking the option updates the chips.
  static const Map<String, String> _conditionToOption = {
    'like new': 'like-new',
    'good': 'good',
    'fair': 'fair',
    'poor': 'needs-repair',
  };
  static final Map<String, String> _optionToCondition = {
    for (final e in _conditionToOption.entries) e.value: e.key,
  };

  bool get _isEditMode => widget.editListingId != null;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    final p = widget.profile ?? AppState.instance.profile;
    if (p != null) {
      if (p.latitude != null && p.longitude != null) {
        _location = LatLng(p.latitude!, p.longitude!);
      }
      if (p.city != null && p.city!.isNotEmpty && _cities.contains(p.city)) {
        _cityDropdown = p.city;
      }
    }
    if (_isEditMode) _loadForEdit();
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _price.dispose();
    _originalPrice.dispose();
    _subCity.dispose();
    _deliveryFee.dispose();
    _shopNameCtrl.dispose();
    for (final c in _attrText.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// The most specific selected category — attributes resolve against it.
  String? get _effectiveCategoryId => _categoryId;

  /// Category-attribute definition for "Condition", if the selected category
  /// configures one (matched by slug or name, select-type only).
  CategoryAttributeDef? get _conditionAttrDef {
    for (final d in _attrDefs) {
      if (d.isSelect &&
          (d.slug == 'condition' ||
              d.name.toLowerCase().trim() == 'condition')) {
        return d;
      }
    }
    return null;
  }

  /// Root → … → leaf id chain for [leafId]; empty when unknown.
  List<String> _ancestorPath(String? leafId, List<Category> cats) {
    final byId = <String, Category>{for (final c in cats) c.id: c};
    final path = <String>[];
    var cur = leafId == null ? null : byId[leafId];
    while (cur != null) {
      path.insert(0, cur.id);
      final parentId = cur.parentId;
      cur = parentId == null ? null : byId[parentId];
    }
    return path;
  }

  Future<void> _loadAttrDefs({bool prefill = false}) async {
    final id = _effectiveCategoryId;
    if (id == null) {
      setState(() => _attrDefs = const []);
      return;
    }
    try {
      final defs = await _repo.fetchCategoryAttributes(id);
      if (!mounted) return;
      // Seed empty selection state for the new definitions.
      for (final d in defs) {
        if (d.type == 'text' || d.type == 'number' || d.type == 'range') {
          _attrText.putIfAbsent(d.attributeId, TextEditingController.new);
        } else if (d.type == 'single_select') {
          _attrSingle.putIfAbsent(d.attributeId, () => null);
        } else if (d.type == 'multi_select') {
          _attrMulti.putIfAbsent(d.attributeId, () => <String>{});
        } else if (d.type == 'boolean') {
          _attrBool.putIfAbsent(d.attributeId, () => false);
        }
      }
      if (prefill && _existingAttrValues.isNotEmpty) _seedAttrSelections(defs);
      setState(() => _attrDefs = defs);
    } catch (_) {
      // Attribute loading is best-effort; required ones are still enforced
      // by the backend at publish time.
    }
  }

  void _seedAttrSelections(List<CategoryAttributeDef> defs) {
    for (final def in defs) {
      final rows =
          _existingAttrValues.where((r) => r.attributeId == def.attributeId);
      if (rows.isEmpty) continue;
      if (def.type == 'text') {
        _attrText[def.attributeId]?.text = rows.first.valueText ?? '';
      } else if (def.type == 'number' || def.type == 'range') {
        final n = rows.first.valueNumber;
        _attrText[def.attributeId]?.text =
            n == null ? '' : n.toStringAsFixed(0);
      } else if (def.type == 'boolean') {
        _attrBool[def.attributeId] = rows.first.valueBoolean ?? false;
      } else if (def.type == 'single_select') {
        _attrSingle[def.attributeId] = rows.first.optionId;
      } else if (def.type == 'multi_select') {
        _attrMulti[def.attributeId] = {
          for (final r in rows)
            if (r.optionId != null) r.optionId!,
        };
      }
    }
  }

  /// Build value rows from the current selections and collect the names of
  /// required attributes that are still empty (spec §12).
  ({List<ListingAttributeValue> rows, List<String> missing}) _collectAttrValues() {
    final rows = <ListingAttributeValue>[];
    final missing = <String>[];
    for (final def in _attrDefs) {
      final id = def.attributeId;
      switch (def.type) {
        case 'text':
          final t = _attrText[id]?.text.trim() ?? '';
          if (t.isNotEmpty) rows.add(ListingAttributeValue(attributeId: id, valueText: t));
          if (def.isRequired && t.isEmpty) missing.add(def.name);
        case 'number' || 'range':
          final n = double.tryParse(_attrText[id]?.text.trim() ?? '');
          if (n != null) rows.add(ListingAttributeValue(attributeId: id, valueNumber: n));
          if (def.isRequired && n == null) missing.add(def.name);
        case 'boolean':
          rows.add(ListingAttributeValue(attributeId: id, valueBoolean: _attrBool[id] ?? false));
        case 'single_select':
          final o = _attrSingle[id];
          if (o != null) rows.add(ListingAttributeValue(attributeId: id, optionId: o));
          if (def.isRequired && o == null) missing.add(def.name);
        case 'multi_select':
          final sel = _attrMulti[id] ?? const <String>{};
          for (final o in sel) {
            rows.add(ListingAttributeValue(attributeId: id, optionId: o));
          }
          if (def.isRequired && sel.isEmpty) missing.add(def.name);
      }
    }
    return (rows: rows, missing: missing);
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await _listingsRepo.getCategories();
      if (!mounted) return;
      setState(() => _categories = cats);
    } catch (_) {}
  }

  Future<void> _loadForEdit() async {
    final id = widget.editListingId;
    if (id == null) return;
    setState(() => _loadingEdit = true);
    try {
      // The category chips' path is built from _categories; make sure they
      // are loaded ( initState() fires both loads without awaiting).
      if (_categories.isEmpty) await _loadCategories();
      final item = await _repo.fetchListingForEdit(id);
      if (!mounted || item == null) return;
      setState(() {
        _editing = true;
        _title.text = item.title;
        _description.text = item.description;
        _price.text = item.price.toStringAsFixed(0);
        _originalPrice.text = item.originalPrice?.toStringAsFixed(0) ?? '';
        _negotiable = item.negotiable;
        _condition = item.condition.isNotEmpty ? item.condition : _condition;
        if (_cities.contains(item.city)) _cityDropdown = item.city;
        // Keep a stored sub-city only if it matches the dropdown options.
        final sc = item.subCity ?? '';
        _subCityValue =
            SupabaseApi.addisSubCities.any((s) => s.toLowerCase() == sc.toLowerCase())
                ? SupabaseApi.addisSubCities
                    .firstWhere((s) => s.toLowerCase() == sc.toLowerCase())
                : null;
        _delivery = item.deliveryOffered;
        _deliveryFee.text = item.deliveryFee?.toStringAsFixed(0) ?? '';
        _discountDate = item.discountExpiresAt?.toIso8601String();
        _location = (item.latitude != null && item.longitude != null)
            ? LatLng(item.latitude!, item.longitude!)
            : _location;
        _videoUrl = item.videoUrl;
        _videoExisting = item.videoUrl != null;
        // Rebuild the category path by walking the parent chain, so the
        // cascading picker shows every level of an existing listing.
        _catPath = _categories.isEmpty
            ? const []
            : _ancestorPath(item.categoryId, _categories);
        _images = [
          for (final img in item.images)
            _SellImage(url: img.url, isExisting: true),
        ];
      });
      // Load existing attribute values, then resolve the category's
      // definitions and prefill the dynamic fields from them.
      try {
        final vals = await _repo.fetchListingAttributeValues(id);
        if (!mounted) return;
        _existingAttrValues = vals;
      } catch (_) {}
      await _loadAttrDefs(prefill: true);
    } catch (_) {
      // Seed failure keeps the form in create mode; the seller can retype.
    } finally {
      if (mounted) setState(() => _loadingEdit = false);
    }
  }

  Future<void> _pickImages() async {
    final state = AppState.instance;
    final source = await showModalBottomSheet<_ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(state.t('sell.takePhoto')),
              onTap: () => Navigator.pop(ctx, _ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(state.t('sell.chooseGallery')),
              onTap: () => Navigator.pop(ctx, _ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picker = ImagePicker();
    final XFile? single;
    final List<XFile> picked;
    if (source == _ImageSource.camera) {
      single = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: _kPhotoMaxEdge.toDouble(),
        maxHeight: _kPhotoMaxEdge.toDouble(),
        imageQuality: _kPhotoQuality,
      );
      if (single == null) return;
      picked = [single];
    } else {
      picked = await picker.pickMultiImage(
        limit: 10 - _images.length,
        maxWidth: _kPhotoMaxEdge.toDouble(),
        maxHeight: _kPhotoMaxEdge.toDouble(),
        imageQuality: _kPhotoQuality,
      );
      if (picked.isEmpty) return;
    }
    setState(() {
      _images = [
        ..._images,
        ...picked.map((f) => _SellImage(file: f, isExisting: false)),
      ];
    });
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final file = await picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60));
    if (file == null) return;
    final tooLong = await _videoLongerThan(file, const Duration(seconds: 60));
    if (!mounted) return;
    if (tooLong) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppState.instance.t('sell.videoTooLong'))));
      return;
    }
    setState(() {
      _video = file;
      _videoUrl = null;
      _videoExisting = false;
    });
  }

  Future<bool> _videoLongerThan(XFile file, Duration limit) async {
    try {
      final ctrl = VideoPlayerController.file(File(file.path));
      await ctrl.initialize();
      final duration = ctrl.value.duration;
      await ctrl.dispose();
      return duration > limit;
    } catch (_) {
      return false; // Best-effort; don't block upload if duration can't be read.
    }
  }

  void _removeImage(int index) {
    setState(() => _images = [..._images]..removeAt(index));
  }

  Future<void> _publish([bool asDraft = false]) async {
    final state = AppState.instance;
    final profile = state.profile;
    if (profile == null) return;

    final priceRaw = double.tryParse(_price.text);
    if (_title.text.trim().isEmpty) {
      _snack(state.t('sell.titleRequired'));
      return;
    }
    final double price;
    if (asDraft) {
      price = priceRaw == null || priceRaw < 0 ? 0 : priceRaw;
    } else if (priceRaw == null || priceRaw <= 0) {
      _snack(state.t('sell.titlePriceRequired'));
      return;
    } else {
      price = priceRaw;
    }
    final status = asDraft ? 'draft' : 'active';

    // Dynamic category attributes (spec §12): required ones must be provided
    // before publishing. Drafts may omit them.
    List<ListingAttributeValue> attrRows = const [];
    if (_attrDefs.isNotEmpty) {
      final collected = _collectAttrValues();
      if (!asDraft && collected.missing.isNotEmpty) {
        _snack('${state.t('sell.attrMissing')}: ${collected.missing.join(', ')}');
        return;
      }
      attrRows = collected.rows;
    }

    setState(() => _busy = true);
    try {
      final uploadedPaths = <String>[];
      for (final img in _images) {
        if (img.isExisting) {
          uploadedPaths.add(img.url!);
        } else {
          final path = await _repo.uploadImage(profile.id, img.file!);
          uploadedPaths.add(path);
        }
      }

      String? videoUrl;
      final video = _video;
      if (video != null) {
        videoUrl = await _repo.uploadVideo(profile.id, video);
      } else if (_videoExisting && _videoUrl != null) {
        videoUrl = _videoUrl;
      }

      var lat = _location?.latitude;
      var lon = _location?.longitude;
      final subCity = _cityDropdown == 'Addis Ababa'
          ? (_subCityValue ?? '')
          : _subCity.text.trim();
      if (lat == null && lon == null && subCity.isNotEmpty) {
        final c = SupabaseApi.coordsForSubCity(subCity);
        if (c != null) {
          lat = c.lat;
          lon = c.lng;
        }
      }
      final categoryId = _categoryId;

      if (_isEditMode && _editing) {
        final id = widget.editListingId!;
        // Values are saved first: updating the row re-fires the backend
        // required-attribute check, so a category switch must already have
        // its values in place.
        await _repo.saveListingAttributeValues(id, _attrDefs, attrRows);
        await _repo.updateListing(id, {
          'title': _title.text.trim(),
          'description': _description.text.trim(),
          'price': price,
          'original_price': _originalPrice.text.trim().isEmpty ? null : double.tryParse(_originalPrice.text),
          'negotiable': _negotiable,
          'condition': _condition ?? 'good',
          'city': _cityDropdown ?? 'Addis Ababa',
          'sub_city': subCity.isEmpty ? null : subCity,
          'category_id': categoryId,
          'delivery_offered': _delivery,
          'delivery_fee': _delivery ? double.tryParse(_deliveryFee.text) : null,
          'discount_expires_at': _discountDate,
          'latitude': lat,
          'longitude': lon,
          'video_url': videoUrl,
          'status': status,
        });
        await _repo.replaceListingImages(id, uploadedPaths);
        if (!mounted) return;
        _snack(state.t(asDraft ? 'sell.draftUpdated' : 'sell.updated'));
      } else {
        // Draft → values → activate, so the backend's publish-time check sees
        // the attribute values when the listing goes live.
        final newId = await _repo.createListing(
          sellerId: profile.id,
          title: _title.text.trim(),
          description: _description.text.trim(),
          price: price,
          originalPrice: _originalPrice.text.trim().isEmpty ? null : double.tryParse(_originalPrice.text),
          negotiable: _negotiable,
          condition: _condition ?? 'good',
          city: _cityDropdown ?? 'Addis Ababa',
          subCity: subCity.isEmpty ? null : subCity,
          categoryId: categoryId,
          deliveryOffered: _delivery,
          deliveryFee: _delivery ? double.tryParse(_deliveryFee.text) : null,
          latitude: lat,
          longitude: lon,
          discountExpiresAt: _discountDate != null ? DateTime.tryParse(_discountDate!) : null,
          videoUrl: videoUrl,
          imagePaths: uploadedPaths,
          status: 'draft',
        );
        await _repo.saveListingAttributeValues(newId, _attrDefs, attrRows);
        if (!asDraft) {
          await _repo.updateListing(newId, {'status': 'active'});
        }
        if (!mounted) return;
        _snack(state.t(asDraft ? 'sell.draftSaved' : 'sell.saved'));
      }
      if (!mounted) return;
      if (_isEditMode) {
        Navigator.of(context, rootNavigator: true).pop();
        return;
      }
      setState(() => _uploaded = true);
      _reset();
    } catch (e) {
      if (!mounted) return;
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reset() {
    _title.clear();
    _description.clear();
    _price.clear();
    _originalPrice.clear();
    _subCity.clear();
    _deliveryFee.clear();
    _condition = 'good';
    _catPath = const [];
    _images = const [];
    _video = null;
    _videoUrl = null;
    _videoExisting = false;
    _discountDate = null;
    _location = null;
    _negotiable = true;
    _delivery = false;
    _cityDropdown = 'Addis Ababa';
    _subCityValue = null;
    _attrDefs = const [];
    _existingAttrValues = const [];
    for (final c in _attrText.values) {
      c.clear();
    }
    _attrSingle.clear();
    for (final s in _attrMulti.values) {
      s.clear();
    }
    for (final k in _attrBool.keys.toList()) {
      _attrBool[k] = false;
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _syncShopFields(Profile? p) {
    if (p == null) return;
    if (_shopNameCtrl.text.isEmpty && p.shopName != null) {
      _shopNameCtrl.text = p.shopName!;
    }
  }

  String _slugFor(String name, String uid) {
    final slug = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isNotEmpty) return slug;
    final short = uid.replaceAll('-', '');
    final seed = short.isEmpty ? DateTime.now().millisecondsSinceEpoch.toString() : short;
    return 'shop-${seed.substring(0, seed.length > 8 ? 8 : seed.length)}';
  }

  Future<void> _createShop() async {
    final state = AppState.instance;
    final uid = state.userId;
    if (uid == null) return;

    final name = _shopNameCtrl.text.trim();
    if (name.isEmpty) {
      _snack(state.t('sell.enterShopName'));
      return;
    }
    final slug = _slugFor(name, uid);

    setState(() => _busy = true);
    try {
      final profileRepo = sl<ProfileRepository>();
      await profileRepo.updateProfile(uid, {
        'is_seller': true,
        'shop_name': name,
        'shop_slug': slug,
      });
      await state.refreshProfile();
      _snack('Shop created successfully!');
    } catch (e) {
      _snack('Failed to create shop: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final profile = state.profile;
    final theme = Theme.of(context);

    if (profile == null) {
      return Scaffold(
        appBar: AppBar(title: Text(state.t(_isEditMode ? 'sell.editTitle' : 'sell.title'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final isSeller = profile.isSeller;

    if (!isSeller) {
      _syncShopFields(profile);
      return Scaffold(
        appBar: AppBar(title: Text(state.t('sell.title'))),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outlineVariant, width: 1.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(Icons.storefront, size: 34, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    state.t('sell.setupTitle'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state.t('sell.shopNamePrompt'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _shopNameCtrl,
                    decoration: InputDecoration(
                      labelText: state.t('profile.shopName'),
                      prefixIcon: const Icon(Icons.storefront_outlined),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _createShop,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(state.t('profile.save')),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(state.t(_isEditMode ? 'sell.editTitle' : 'sell.title'))),
      body: _loadingEdit
          ? const Center(child: CircularProgressIndicator())
          : _uploaded
              ? EmptyState(
                  icon: Icons.check_circle_outline,
                  title: state.t('sell.saved'),
                  body: state.t('home.freshListings'),
                  actionLabel: state.t('sell.title'),
                  onAction: () => setState(() => _uploaded = false),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextField(
                      controller: _title,
                      decoration: InputDecoration(labelText: state.t('sell.titleLabel')),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _description,
                      maxLines: 4,
                      decoration: InputDecoration(labelText: state.t('sell.description')),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _price,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(labelText: state.t('sell.price')),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _originalPrice,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(labelText: state.t('sell.originalPrice')),
                          ),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(state.t('sell.negotiable')),
                      value: _negotiable,
                      onChanged: (v) => setState(() => _negotiable = v),
                    ),
                    if (_originalPrice.text.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _label(state.t('sell.discountEnds')),
                      CalendarPicker(value: _discountDate, onChange: (v) => setState(() => _discountDate = v)),
                    ],

                    const SizedBox(height: 8),
                    _label(state.t('sell.category')),
                    // Full-depth cascading selection: one row of chips per
                    // level of the category tree. Picking a level narrows the
                    // next row to its children; attributes always resolve
                    // against the deepest selection.
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (int level = 0; level <= _catPath.length; level++)
                          for (final c in _categories.where(
                            (c) => c.parentId ==
                                (level == 0 ? null : _catPath[level - 1]),
                          ))
                            ChoiceChip(
                              label: Text(
                                state.lang == 'am' && c.nameAm != null
                                    ? c.nameAm!
                                    : c.name,
                              ),
                              selected: level < _catPath.length &&
                                  _catPath[level] == c.id,
                              onSelected: (_) {
                                setState(() {
                                  _catPath = [
                                    ..._catPath.sublist(0, level),
                                    c.id,
                                  ];
                                });
                                _loadAttrDefs();
                              },
                            ),
                      ],
                    ),

                    const SizedBox(height: 16),
                    _label(state.t('sell.condition')),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final cond in _conditions)
                          ChoiceChip(
                            label: Text(cond),
                            selected: _condition == cond,
                            onSelected: (_) => setState(() {
                              _condition = cond;
                              // Keep the dynamic Condition attribute in step.
                              final def = _conditionAttrDef;
                              if (def != null) {
                                final value = _conditionToOption[cond];
                                for (final o in def.options) {
                                  if (o.value == value) {
                                    _attrSingle[def.attributeId] = o.id;
                                    break;
                                  }
                                }
                              }
                            }),
                          ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Dynamic attributes for the selected category (spec §15) —
                    // loaded from the backend, so admin changes appear here
                    // without a release.
                    if (_attrDefs.isNotEmpty) ...[
                      _label(state.t('sell.attrHint')),
                      for (final def in _attrDefs)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _attrField(theme, def),
                        ),
                      const SizedBox(height: 4),
                    ],

                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _cityDropdown,
                            isExpanded: true,
                            decoration:
                                InputDecoration(labelText: state.t('sell.city')),
                            items: [
                              for (final c in _cities)
                                DropdownMenuItem(value: c, child: Text(c)),
                            ],
                            onChanged: (v) => setState(() {
                              _cityDropdown = v;
                              if (v != 'Addis Ababa') _subCityValue = null;
                            }),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _cityDropdown == 'Addis Ababa'
                              ? DropdownButtonFormField<String>(
                                  initialValue: _subCityValue,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                      labelText: state.t('sell.subCity')),
                                  items: [
                                    for (final s in SupabaseApi.addisSubCities)
                                      DropdownMenuItem(value: s, child: Text(s)),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _subCityValue = v),
                                )
                              : TextField(
                                  controller: _subCity,
                                  decoration: InputDecoration(
                                      labelText: state.t('sell.subCity')),
                                ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),
                    _label(state.t('sell.setLocation')),
                    DraggablePinMap(
                      value: _location,
                      onChange: (c) => setState(() => _location = c),
                    ),

                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(state.t('sell.delivery')),
                      value: _delivery,
                      onChanged: (v) => setState(() => _delivery = v),
                    ),
                    if (_delivery)
                      TextField(
                        controller: _deliveryFee,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: state.t('sell.deliveryFee')),
                      ),

                    const SizedBox(height: 20),
                    _label(state.t('sell.photos')),
                    SizedBox(
                      height: 96,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (int i = 0; i < _images.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _imageTile(theme, _images[i], onRemove: () => _removeImage(i)),
                            ),
                          if (_images.length < 6)
                            InkWell(
                              onTap: _pickImages,
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                width: 96,
                                height: 96,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: theme.colorScheme.outlineVariant),
                                ),
                                child: const Icon(Icons.add_a_photo_outlined),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_isEditMode) ...[
                      const SizedBox(height: 4),
                      Text(
                        state.t('sell.keepPhotos'),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],

                    const SizedBox(height: 16),
                    _label(state.t('sell.videoLabel')),
                    if (_video != null)
                      _videoRow(theme, _video!.name)
                    else if (_videoExisting && _videoUrl != null)
                      _videoRow(theme, state.t('sell.videoCurrent'), existing: true)
                    else
                      InkWell(
                        onTap: _pickVideo,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.videocam_outlined, size: 18),
                              const SizedBox(width: 8),
                              Text(state.t('sell.videoAdd'), style: theme.textTheme.bodyMedium),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      state.t('sell.videoHint'),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    ),

                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy ? null : () => _publish(true),
                            icon: const Icon(Icons.drafts_outlined, size: 18),
                            label: Text(state.t('sell.saveDraft')),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: FilledButton(
                            onPressed: _busy ? null : () => _publish(false),
                            child: _busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Text(state.t(_isEditMode ? 'profile.save' : 'sell.publish')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
    );
  }

  Widget _imageTile(ThemeData theme, _SellImage image, {required VoidCallback onRemove}) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: image.isExisting
              ? Image.network(
                  // A 96px tile has no use for the stored original.
                  thumbUrl(image.url!, width: 288)!,
                  width: 96,
                  height: 96,
                  cacheWidth: 288,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 96,
                    height: 96,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.image_outlined),
                  ),
                )
              : FutureBuilder<Uint8List>(
                  future: image.file!.readAsBytes(),
                  builder: (context, snap) {
                    if (snap.hasData) {
                      return Image.memory(
                        snap.data!,
                        width: 96,
                        height: 96,
                        fit: BoxFit.cover,
                      );
                    }
                    return Container(
                      width: 96,
                      height: 96,
                      color: theme.colorScheme.surfaceContainerHighest,
                    );
                  },
                ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _videoRow(ThemeData theme, String name, {bool existing = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.videocam, size: 18, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          ),
          InkWell(
            onTap: () => setState(() {
              _video = null;
              _videoUrl = null;
              _videoExisting = false;
            }),
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close, size: 15, color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  /// One dynamically-configured attribute input (spec §15). The control
  /// matches the attribute's type; selections live in the per-attribute maps
  /// that [_collectAttrValues] reads at publish time.
  Widget _attrField(ThemeData theme, CategoryAttributeDef def) {
    final id = def.attributeId;
    final label =
        '${AppState.instance.lang == 'am' && def.nameAm != null ? def.nameAm! : def.name}'
        '${def.unit != null ? ' (${def.unit})' : ''}'
        '${def.isRequired ? ' *' : ''}';

    switch (def.type) {
      case 'boolean':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(label),
          value: _attrBool[id] ?? false,
          onChanged: (v) => setState(() => _attrBool[id] = v),
        );
      case 'single_select':
        return DropdownButtonFormField<String>(
          initialValue: _attrSingle[id],
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            for (final o in def.options)
              DropdownMenuItem(
                value: o.id,
                child: Text(
                  AppState.instance.lang == 'am' && o.labelAm != null
                      ? o.labelAm!
                      : o.label,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() {
            _attrSingle[id] = v;
            // Options → condition chips, when this is the Condition attribute.
            if (def.attributeId == _conditionAttrDef?.attributeId && v != null) {
              for (final o in def.options) {
                if (o.id == v) {
                  final chip = _optionToCondition[o.value];
                  if (chip != null) _condition = chip;
                  break;
                }
              }
            }
          }),
        );
      case 'multi_select':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in def.options)
                  FilterChip(
                    label: Text(
                      AppState.instance.lang == 'am' && o.labelAm != null
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
      default: // text / number / range
        return TextField(
          controller: _attrText[id],
          keyboardType:
              def.type == 'text' ? TextInputType.text : TextInputType.number,
          decoration: InputDecoration(labelText: label),
        );
    }
  }
}