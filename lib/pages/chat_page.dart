import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

import 'chat_screen.dart';
import 'private_chat_screen.dart';
import 'community_page.dart';
import 'me_page.dart';
import 'notification.dart';
import 'app_theme.dart';
import 'nexus_bottom_nav.dart';
import '../services/chat_settings_service.dart';
import 'package:flutter/foundation.dart';

import '../widgets/top_alert.dart';
// ================================================================
// PROFILE IMAGE PROVIDER
// ----------------------------------------------------------------
// Public and (once two accounts are connected) private profile
// pictures are uploaded to Cloudinary and stored as https:// URLs
// in Firestore ('publicImage' / 'privateImage'). They are NOT
// bundled app assets, so they must be loaded with NetworkImage,
// not AssetImage. AssetImage silently fails to resolve an http(s)
// URL, which is why connected accounts' private profile pictures
// were not appearing anywhere on the Chats page. Local/bundled
// asset paths (no http/https scheme) still fall back to AssetImage
// so nothing that previously relied on a bundled asset breaks.
// ================================================================

ImageProvider? _profileImageProvider(String path) {
  final value = path.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return NetworkImage(value);
  }
  return AssetImage(value);
}

// ================================================================
// CHATS PAGE
// ----------------------------------------------------------------
// (File kept as chat_page.dart / class ChatPage for backward
// compatibility with splash_screen.dart + login_page.dart, which
// both navigate to `const ChatPage()`.)
//
// This screen now displays itself as "Chats" everywhere (title,
// bottom nav label + icon) instead of "Home" / "Nexus".
// ================================================================

class ChatPage extends StatefulWidget {
  // ==============================================================
  // HOME-SHELL INTEGRATION (Chats <-> Me instant switching)
  // --------------------------------------------------------------
  // When ChatPage is hosted inside HomeShell (see home_shell.dart),
  // the shell supplies `onSwitchToMe` so tapping "Me" in the bottom
  // nav just flips the shell's IndexedStack index instead of pushing
  // a brand-new MePage route -- this ChatPage's State (and every
  // Firestore listener/subscription it owns) stays alive and simply
  // stops being painted, rather than being disposed and rebuilt from
  // scratch on every switch.
  //
  // `publicResetSignal` lets MePage ask this already-alive ChatPage
  // to snap back to the Public tab (used by the Me -> Chats swipe
  // gesture, which has always meant "take me to Public Chats
  // specifically") without recreating the widget.
  //
  // Both are optional and default to null so `const ChatPage()` from
  // splash_screen.dart's initial-launch fallback continues to work
  // unchanged if this widget is ever used outside the shell.
  // ==============================================================
  final VoidCallback? onSwitchToMe;
  final VoidCallback? onSwitchToCommunity;
  final ValueListenable<int>? publicResetSignal;

  const ChatPage({
    super.key,
    this.onSwitchToMe,
    this.onSwitchToCommunity,
    this.publicResetSignal,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage>
    with TickerProviderStateMixin {
  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();

  bool searchingUser = false;

  // Account-ID search is intentionally state-driven instead of a StreamBuilder
  // created on every keystroke. Recreating the Firestore stream while the
  // TextField is focused was the source of the Flutter framework
  // `_dependents.isEmpty` assertion seen when entering 10+ digits.
  Map<String, dynamic>? _accountIdSearchResult;
  Timer? _accountIdSearchDebounce;
  int _accountIdSearchRequest = 0;

  // Public / Private toggle — starts on Public per spec.
  bool showPrivate = false;

  // Chat message search mode.
  bool chatSearchMode = false;
  bool _messageSearchLoading = false;

  // Connected-account uids (for Public/Private split + private
  // profile display + the brown "connected" indicator in search).
  final Set<String> _connectedUids = {};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _connectionsSub;

  // Cache of resolved user docs (uid -> data) so search suggestions
  // can be computed without extra network round-trips.
  final Map<String, Map<String, dynamic>> _userCache = {};

  // Cache of each chat's other-participant uid, keyed by chat doc id.
  final Map<String, String> _chatOtherUid = {};

  // Message cache for Chat Search Mode: chatId -> recent messages.
  final Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _messageCache = {};

  // Animated cream trace border (search bar focus outline).
  late final AnimationController _searchBorderController;

  @override
  void initState() {
    super.initState();

    _searchBorderController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    searchFocusNode.addListener(_onSearchFocusChanged);

    _listenConnections();

    widget.publicResetSignal?.addListener(_onPublicResetSignal);
  }

  // ==========================================================
  // HOME-SHELL: forced switch back to Public Chats
  // ----------------------------------------------------------
  // Fired by HomeShell when the Me page's swipe-to-Chats gesture
  // requests Public specifically. This ChatPage instance is never
  // rebuilt by the shell, so this is the only way for that gesture
  // to reach it.
  // ==========================================================

  void _onPublicResetSignal() {
    if (!mounted) return;
    if (chatSearchMode || searchController.text.isNotEmpty) {
      setState(() {
        showPrivate = false;
        chatSearchMode = false;
        searchController.clear();
        searchFocusNode.unfocus();
      });
      _syncSearchBorderAnimation();
    } else if (showPrivate) {
      setState(() => showPrivate = false);
    }
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.publicResetSignal != widget.publicResetSignal) {
      oldWidget.publicResetSignal?.removeListener(_onPublicResetSignal);
      widget.publicResetSignal?.addListener(_onPublicResetSignal);
    }
  }

  void _onSearchFocusChanged() {
    _syncSearchBorderAnimation();
  }

  // ==========================================================
  // SEARCH BAR BORDER ANIMATION
  // ----------------------------------------------------------
  // The cream trace border must only be in motion while the user is
  // actively typing/searching -- i.e. the search field is focused
  // AND currently has text in it. It must NOT loop continuously just
  // because the field is focused-but-empty or focused-and-idle; and
  // it must stop as soon as the field is cleared or loses focus. The
  // visible fade in/out is handled by `_AnimatedTraceBorder` itself
  // (AnimatedOpacity keyed off the same `active` condition below) --
  // this method only owns starting/stopping the underlying
  // AnimationController so it never keeps ticking in the background.
  // Called from the focus listener, on every keystroke, and from any
  // place that mutates `searchController`/focus programmatically
  // (e.g. the clear button, chat-search-mode toggle, the Me -> Chats
  // "reset to Public" signal) so the two can never fall out of sync.
  // ==========================================================

  void _syncSearchBorderAnimation() {
    final bool shouldAnimate =
        searchFocusNode.hasFocus && searchController.text.trim().isNotEmpty;

    if (shouldAnimate) {
      if (!_searchBorderController.isAnimating) {
        _searchBorderController.repeat();
      }
    } else if (_searchBorderController.isAnimating) {
      _searchBorderController.stop();
    }

    if (mounted) setState(() {});
  }

  void _listenConnections() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _connectionsSub = FirebaseFirestore.instance
        .collection('connections')
        .where('users', arrayContains: user.uid)
        .where('status', isEqualTo: 'connected')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;

      final uids = <String>{};

      for (final doc in snapshot.docs) {
        final users = List<String>.from(doc.data()['users'] ?? []);
        final otherUid = users.firstWhere(
          (id) => id != user.uid,
          orElse: () => '',
        );
        if (otherUid.isNotEmpty) uids.add(otherUid);
      }

      setState(() {
        _connectedUids
          ..clear()
          ..addAll(uids);
      });
    });
  }

  @override
  void dispose() {
    widget.publicResetSignal?.removeListener(_onPublicResetSignal);
    _connectionsSub?.cancel();
    _accountIdSearchDebounce?.cancel();
    searchFocusNode.removeListener(_onSearchFocusChanged);
    searchFocusNode.dispose();
    searchController.dispose();
    _searchBorderController.dispose();
    super.dispose();
  }

  // ==========================================================
  // USER DATA CACHE (also feeds name-based search suggestions)
  // ==========================================================

  Future<Map<String, dynamic>?> _getUserData(String uid) async {
    if (_userCache.containsKey(uid)) return _userCache[uid];

    final doc =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();

    final data = doc.data();

    if (data != null) {
      _userCache[uid] = data;
      if (mounted) setState(() {});
    }

    return data;
  }

  // ==========================================================
  // PRIVATE / PUBLIC DISPLAY RESOLUTION
  // ----------------------------------------------------------
  // Connected accounts should show their private name/image
  // whenever those fields have actually been set. An empty
  // string ('') is Firestore's default for a never-configured
  // private field, so it must be treated the same as "not set"
  // -- otherwise `privateName ?? publicName` never falls back
  // (since '' is not null) and the public info gets hidden
  // behind a blank value instead of showing correctly.
  // ==========================================================

  String _resolveDisplayName({
    required Map<String, dynamic>? userData,
    required bool isConnected,
  }) {
    if (userData == null) return '';

    final String privateName = (userData['privateName'] ?? '').toString().trim();
    final String publicName = (userData['publicName'] ?? '').toString().trim();

    if (isConnected && privateName.isNotEmpty) {
      return privateName;
    }

    return publicName;
  }

  String _resolveDisplayImage({
    required Map<String, dynamic>? userData,
    required bool isConnected,
  }) {
    if (userData == null) return '';

    final String privateImage =
        (userData['privateImage'] ?? '').toString().trim();
    final String publicImage =
        (userData['publicImage'] ?? '').toString().trim();

    if (isConnected && privateImage.isNotEmpty) {
      return privateImage;
    }

    return publicImage;
  }

  // ==========================================================
  // SEARCH BY EXACT ACCOUNT ID (10-character Account ID)
  // ==========================================================

  Future<void> _searchUser() async {
    final searchText = searchController.text.trim();

    if (searchText.length != 10) {
      showTopAlert(context, 'Enter a valid 10-digit Account ID');
      return;
    }

    setState(() {
      searchingUser = true;
    });

    try {
      final result = await FirebaseFirestore.instance
          .collection('users')
          .where('userId', isEqualTo: searchText)
          .limit(1)
          .get();

      if (!mounted) return;

      setState(() {
        searchingUser = false;
      });

      if (result.docs.isEmpty) {
        showTopAlert(context, 'User not found', isError: true);
        return;
      }

      final data = Map<String, dynamic>.from(result.docs.first.data());
      data['uid'] = (data['uid'] ?? result.docs.first.id).toString();

      _showSearchResult(data);
    } catch (e) {
      debugPrint('User search error: $e');

      if (!mounted) return;

      setState(() {
        searchingUser = false;
      });

      showTopAlert(context, 'Search failed. Please try again.', isError: true);
    }
  }

  /// Firestore account-ID lookup used only after the user has entered
  /// the complete 10-character Account ID (letters, digits and symbols
  /// are all valid — Account IDs are not purely numeric). The result is
  /// stored in state so the build method never creates/cancels a
  /// Firestore stream while the keyboard is active.
  void _handleSearchChanged(String raw) {
    final text = raw.trim();
    _accountIdSearchDebounce?.cancel();

    if (!mounted) return;

    _syncSearchBorderAnimation();

    if (text.length != 10) {
      if (_accountIdSearchResult != null || searchingUser) {
        setState(() {
          _accountIdSearchResult = null;
          searchingUser = false;
        });
      } else {
        setState(() {});
      }
      return;
    }

    final requestId = ++_accountIdSearchRequest;
    _accountIdSearchDebounce = Timer(const Duration(milliseconds: 250), () {
      _lookupAccountId(text, requestId);
    });
    setState(() {});
  }

  Future<void> _lookupAccountId(String accountId, int requestId) async {
    if (!mounted || requestId != _accountIdSearchRequest) return;

    setState(() {
      searchingUser = true;
      _accountIdSearchResult = null;
    });

    try {
      final result = await FirebaseFirestore.instance
          .collection('users')
          .where('userId', isEqualTo: accountId)
          .limit(1)
          .get();

      if (!mounted || requestId != _accountIdSearchRequest) return;

      Map<String, dynamic>? data;
      if (result.docs.isNotEmpty) {
        data = Map<String, dynamic>.from(result.docs.first.data());
        data['uid'] = (data['uid'] ?? result.docs.first.id).toString();
      }

      setState(() {
        searchingUser = false;
        _accountIdSearchResult = data;
      });
    } catch (e) {
      debugPrint('Account ID search error: $e');
      if (!mounted || requestId != _accountIdSearchRequest) return;
      setState(() {
        searchingUser = false;
        _accountIdSearchResult = null;
      });
    }
  }

  /// Name-based suggestions come ONLY from chats the user already has —
  /// never a database-wide public-name search.
  List<Map<String, dynamic>> _nameSuggestionsFromChats(
    String query,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> chatDocs,
    String myUid,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];

    final results = <Map<String, dynamic>>[];

    for (final chat in chatDocs) {
      final data = chat.data();

      final hiddenFor = List<String>.from(data['hiddenFor'] ?? []);
      if (hiddenFor.contains(myUid)) continue;

      final participants = List<String>.from(data['participants'] ?? []);
      final otherUid =
          participants.firstWhere((id) => id != myUid, orElse: () => '');
      if (otherUid.isEmpty) continue;

      final userData = _userCache[otherUid];
      if (userData == null) continue;

      final isConnected = _connectedUids.contains(otherUid);

      final displayName =
          _resolveDisplayName(userData: userData, isConnected: isConnected);

      if (displayName.isEmpty) continue;

      if (displayName.toLowerCase().contains(q)) {
        final displayImage =
            _resolveDisplayImage(userData: userData, isConnected: isConnected);

        results.add({
          ...userData,
          'uid': otherUid,
          'chatDocId': chat.id,
          'isConnected': isConnected,
          'displayName': displayName,
          'displayImage': displayImage,
        });
      }
    }

    results.sort((a, b) {
      final an = (a['displayName'] as String).toLowerCase();
      final bn = (b['displayName'] as String).toLowerCase();
      final aStarts = an.startsWith(q) ? 0 : 1;
      final bStarts = bn.startsWith(q) ? 0 : 1;
      if (aStarts != bStarts) return aStarts - bStarts;
      return an.compareTo(bn);
    });

    return results;
  }

  // ==========================================================
  // CHAT MESSAGE SEARCH MODE
  // ==========================================================

  Future<void> _toggleChatSearchMode() async {
    final enabling = !chatSearchMode;

    setState(() {
      chatSearchMode = enabling;
    });

    if (enabling) {
      await _loadMessagesForSearch();
    }
  }

  Future<void> _loadMessagesForSearch() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _messageSearchLoading = true;
    });

    try {
      final chatsSnap = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .get();

      for (final chat in chatsSnap.docs) {
        final hiddenFor = List<String>.from(chat.data()['hiddenFor'] ?? []);
        if (hiddenFor.contains(user.uid)) continue;

        final participants =
            List<String>.from(chat.data()['participants'] ?? []);
        final otherUid = participants.firstWhere(
          (id) => id != user.uid,
          orElse: () => '',
        );
        if (otherUid.isNotEmpty) {
          _chatOtherUid[chat.id] = otherUid;
          unawaited(_getUserData(otherUid));
        }

        final msgs = await chat.reference
            .collection('messages')
            .orderBy('sentAt', descending: true)
            .limit(300)
            .get();

        _messageCache[chat.id] = msgs.docs;
      }
    } catch (e) {
      debugPrint('Message search preload error: $e');
    }

    if (!mounted) return;

    setState(() {
      _messageSearchLoading = false;
    });
  }

  List<Map<String, dynamic>> _messageSearchResults(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];

    final me = FirebaseAuth.instance.currentUser?.uid ?? '';
    final results = <Map<String, dynamic>>[];

    _messageCache.forEach((chatId, msgs) {
      for (final m in msgs) {
        final data = m.data();

        final hiddenFor = List<String>.from(data['hiddenFor'] ?? []);
        if (hiddenFor.contains(me)) continue;

        final text = (data['text'] ?? '').toString();

        if (text.toLowerCase().contains(q)) {
          final otherUid = _chatOtherUid[chatId] ?? '';
          final userData = _userCache[otherUid];
          final isConnected = _connectedUids.contains(otherUid);

          final name =
              _resolveDisplayName(userData: userData, isConnected: isConnected);
          final image =
              _resolveDisplayImage(userData: userData, isConnected: isConnected);

          results.add({
            'chatId': chatId,
            'messageId': m.id,
            'text': text,
            'otherUid': otherUid,
            'isConnected': isConnected,
            'name': name.isNotEmpty ? name : 'Unknown User',
            'image': image,
          });

          break; // one hit is enough to surface this account.
        }
      }
    });

    return results;
  }

  void _openChatFromSearch({
    required String otherUid,
    required String name,
    required String image,
    String? targetMessageId,
  }) {
    searchFocusNode.unfocus();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          otherUserUid: otherUid,
          otherUserName: name.isNotEmpty ? name : 'Unknown User',
          otherUserImage: image,
          targetMessageId: targetMessageId,
        ),
      ),
    ).then((_) {
      if (mounted) searchFocusNode.unfocus();
    });
  }

  // ==========================================================
  // NEW: SWIPE (RIGHT-TO-LEFT) AN ACCOUNT ID SUGGESTION
  // ----------------------------------------------------------
  // Opens Public Chat directly with the searched account and
  // makes sure that account shows up on the Chats page's chat
  // list right away, instead of only appearing after the first
  // message is sent. Reuses the same 'chats' collection
  // structure/deterministic chat id (sorted uid pair) as
  // ChatScreen's own send-message flow, so:
  //   - it plugs straight into the existing chat-list
  //     StreamBuilder/query (`_buildChats`) with no changes there,
  //   - re-swiping the same suggestion (or the account already
  //     having a chat) can never create a duplicate entry, since
  //     it always resolves to the same document id and merges
  //     into it instead of adding a new one,
  //   - it never touches 'lastMessage' / 'lastMessageTime', so an
  //     existing conversation's preview/ordering is left exactly
  //     as-is.
  // ==========================================================

  Future<void> _openPublicChatFromAccountSuggestion(
    Map<String, dynamic> data,
  ) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final String otherUserUid = (data['uid'] ?? '').toString();

    if (otherUserUid.isEmpty) {
      showTopAlert(context, 'User UID not found.', isError: true);
      return;
    }

    if (otherUserUid == currentUser.uid) {
      showTopAlert(context, 'You cannot chat with yourself');
      return;
    }

    final bool isConnected = _connectedUids.contains(otherUserUid);
    final String name =
        _resolveDisplayName(userData: data, isConnected: isConnected);
    final String image =
        _resolveDisplayImage(userData: data, isConnected: isConnected);
    final String displayName = name.isNotEmpty ? name : 'Unknown User';

    FocusScope.of(context).unfocus();
    searchFocusNode.unfocus();

    try {
      final ids = [currentUser.uid, otherUserUid]..sort();
      final chatId = ids.join('_');

      final chatRef =
          FirebaseFirestore.instance.collection('chats').doc(chatId);

      // Deterministic doc id + merge:true == upsert. Existing
      // chats (and their lastMessage/lastMessageTime/etc.) are
      // left untouched apart from re-surfacing them if the user
      // had previously deleted/hidden the conversation.
      await chatRef.set({
        'participants': [currentUser.uid, otherUserUid],
        'otherUserUid': otherUserUid,
        'hiddenFor': FieldValue.arrayRemove([currentUser.uid]),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Add account to Chats list error: $e');
    }

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          otherUserUid: otherUserUid,
          otherUserName: displayName,
          otherUserImage: image,
        ),
      ),
    ).then((_) {
      if (mounted) searchFocusNode.unfocus();
    });
  }

  // ==========================================================
  // SEND CONNECTION REQUEST
  // ==========================================================

  Future<void> _connectUser({
    required String otherUserUid,
    required String otherUserName,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    if (currentUser.uid == otherUserUid) {
      showTopAlert(context, 'You cannot connect with yourself');
      return;
    }

    try {
      final firestore = FirebaseFirestore.instance;

      final connectionUsers = [currentUser.uid, otherUserUid]..sort();
      final connectionDocId =
          '${connectionUsers[0]}_${connectionUsers[1]}';

      final connectionRef =
          firestore.collection('connections').doc(connectionDocId);

      final existingConnection = await connectionRef.get();

      if (existingConnection.exists) {
        final existingData = existingConnection.data() ?? {};
        final status = (existingData['status'] ?? '').toString();

        if (!mounted) return;

        if (status == 'connected') {
          showTopAlert(context, 'Already connected with $otherUserName');
          return;
        }

        if (status == 'pending') {
          showTopAlert(context, 'Connection request already sent.');
          return;
        }
      }

      final currentUserDoc =
          await firestore.collection('users').doc(currentUser.uid).get();

      final currentUserData = currentUserDoc.data() ?? {};

      final senderName = (currentUserData['privateName'] ??
              currentUserData['publicName'] ??
              'User')
          .toString()
          .trim();

      await connectionRef.set({
        'users': [currentUser.uid, otherUserUid],
        'senderUid': currentUser.uid,
        'receiverUid': otherUserUid,
        'senderName': senderName,
        'receiverName': otherUserName,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      final receiverDoc =
          await firestore.collection('users').doc(otherUserUid).get();

      final receiverData = receiverDoc.data() ?? {};
      final receiverToken =
          (receiverData['fcmToken'] ?? '').toString().trim();

      if (receiverToken.isNotEmpty) {
        final response = await http.post(
          Uri.parse('https://chatbot-worker.gokulmi56cro.workers.dev'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'fcmToken': receiverToken,
            'senderName': senderName,
            'message': '$senderName sent you a connection request',
            'senderUid': currentUser.uid,
            'type': 'connection',
          }),
        );

        debugPrint('Connect notification status: ${response.statusCode}');
      }

      if (!mounted) return;

      showTopAlert(context, 'Connection request sent to $otherUserName');
    } catch (e) {
      debugPrint('Connect request error: $e');

      if (!mounted) return;

      showTopAlert(context, 'Failed to send connection request.', isError: true);
    }
  }

  // ==========================================================
  // UNCONNECT USER
  // ==========================================================

  Future<void> _unconnectUser(String otherUserUid, String otherUserName) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      final users = [currentUser.uid, otherUserUid]..sort();
      final connectionDocId = '${users[0]}_${users[1]}';

      await FirebaseFirestore.instance
          .collection('connections')
          .doc(connectionDocId)
          .delete();

      if (!mounted) return;

      showTopAlert(context, 'Disconnected from $otherUserName');
    } catch (e) {
      debugPrint('Unconnect error: $e');

      if (!mounted) return;

      showTopAlert(context, 'Failed to disconnect.', isError: true);
    }
  }

  void _showUnconnectDialog(String otherUserUid, String otherUserName) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1B120A),
          title: const Text(
            'Disconnect',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Disconnect from $otherUserName?',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text(
                'CANCEL',
                style: TextStyle(color: Color(0xFFD2B48C)),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                await _unconnectUser(otherUserUid, otherUserName);
              },
              child: const Text(
                'DISCONNECT',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // SEARCH RESULT (public account -> connect / message bottom sheet)
  // ==========================================================
  //
  // NOTE: the deeper redesign (three-dot menu: nickname, active info,
  // typing info, mute, block) is intentionally left for the Chat
  // Screen phase, since those settings live alongside the chat
  // screen's own connection/profile logic. This keeps the existing
  // connect/unconnect/message flow fully working in the meantime.
  // ==========================================================

  void _showSearchResult(Map<String, dynamic> data) {
    final String userId = (data['userId'] ?? '').toString();
    final String otherUserUid = (data['uid'] ?? '').toString();

    // Already-connected accounts should show their private name/image
    // here too (this bottom sheet doubles as a search result), with a
    // safe fallback to public info when private fields aren't set.
    final bool isConnected = _connectedUids.contains(otherUserUid);
    final String publicName =
        _resolveDisplayName(userData: data, isConnected: isConnected);
    final String publicImage =
        _resolveDisplayImage(userData: data, isConnected: isConnected);

    final currentUser = FirebaseAuth.instance.currentUser;

    final connectionUsers = [currentUser?.uid ?? '', otherUserUid]..sort();
    final connectionDocId = '${connectionUsers[0]}_${connectionUsers[1]}';

    if (otherUserUid.isEmpty) {
      showTopAlert(context, 'User UID not found.', isError: true);
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B120A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(25),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF2A1B0E),
                    border: Border.all(
                      color: const Color(0xFFD2B48C),
                      width: 2,
                    ),
                  ),
                  child: publicImage.isNotEmpty
                      ? ClipOval(
                          child: Image(
                            image: _profileImageProvider(publicImage)!,
                            fit: BoxFit.cover,
                          ),
                        )
                      : const Icon(
                          Icons.person_rounded,
                          color: Colors.white70,
                          size: 50,
                        ),
                ),
                if (publicName.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    publicName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  userId,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 20),
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('connections')
                      .doc(connectionDocId)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFFD2B48C),
                          ),
                        ),
                      );
                    }

                    String status = 'none';

                    if (snapshot.hasData && snapshot.data!.exists) {
                      final data = snapshot.data!.data() ?? {};
                      final firestoreStatus =
                          (data['status'] ?? '').toString();

                      if (firestoreStatus == 'connected') {
                        status = 'connected';
                      } else if (firestoreStatus == 'pending') {
                        final senderUid = (data['senderUid'] ?? '').toString();
                        final receiverUid =
                            (data['receiverUid'] ?? '').toString();

                        if (senderUid == currentUser!.uid) {
                          status = 'sent';
                        } else if (receiverUid == currentUser.uid) {
                          status = 'received';
                        }
                      }
                    }

                    if (status == 'none') {
                      return Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 50,
                              child: ElevatedButton.icon(
                                onPressed: () async {
                                  await _connectUser(
                                    otherUserUid: otherUserUid,
                                    otherUserName:
                                        publicName.isNotEmpty
                                            ? publicName
                                            : 'Unknown User',
                                  );
                                },
                                icon: const Icon(Icons.person_add_rounded),
                                label: const Text(
                                  'CONNECT',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF8B4513),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SizedBox(
                              height: 50,
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.pop(bottomSheetContext);
                                  searchFocusNode.unfocus();

                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ChatScreen(
                                        otherUserUid: otherUserUid,
                                        otherUserName: publicName.isNotEmpty
                                            ? publicName
                                            : 'Unknown User',
                                        otherUserImage: publicImage,
                                      ),
                                    ),
                                  ).then((_) {
                                    if (mounted) searchFocusNode.unfocus();
                                  });
                                },
                                icon: const Icon(Icons.chat_rounded),
                                label: const Text(
                                  'Message',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2A1B0E),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }

                    if (status == 'sent') {
                      return SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                          onPressed: null,
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text(
                            'Request Sent',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            disabledBackgroundColor: Colors.grey.shade700,
                            disabledForegroundColor: Colors.white70,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      );
                    }

                    if (status == 'received') {
                      return SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A1B0E),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Text(
                            'Request Received',
                            style: TextStyle(
                              color: Colors.white54,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                    }

                    return Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                _showUnconnectDialog(
                                  otherUserUid,
                                  publicName.isNotEmpty
                                      ? publicName
                                      : 'Unknown User',
                                );
                              },
                              icon: const Icon(Icons.check_circle_rounded),
                              label: const Text(
                                'Connected ✓',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF8B4513),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.pop(bottomSheetContext);
                                searchFocusNode.unfocus();

                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ChatScreen(
                                      otherUserUid: otherUserUid,
                                      otherUserName: publicName.isNotEmpty
                                          ? publicName
                                          : 'Unknown User',
                                      otherUserImage: publicImage,
                                    ),
                                  ),
                                ).then((_) {
                                  if (mounted) searchFocusNode.unfocus();
                                });
                              },
                              icon: const Icon(Icons.chat_rounded),
                              label: const Text(
                                'Message',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2A1B0E),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 5),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================================================
  // NOTIFICATIONS — full-screen, dynamic transition
  // ==========================================================

  void _openNotifications() {
    searchFocusNode.unfocus();

    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, _, _) => const NotificationPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );

          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(opacity: curved, child: child),
          );
        },
      ),
    ).then((_) {
      if (mounted) searchFocusNode.unfocus();
    });
  }

  // ==========================================================
  // BOTTOM NAV -> ME
  // ----------------------------------------------------------
  // The Chats page now shares the exact same NexusBottomNav
  // widget the Me page uses (see nexus_bottom_nav.dart), so the
  // one-shot cream trace animation on tab switch is already owned
  // and played by that shared widget itself. This callback only
  // needs to perform the actual navigation, same as before.
  // ==========================================================

  void _goToMePage() {
    searchFocusNode.unfocus();

    // Inside HomeShell this just flips the IndexedStack index -- this
    // ChatPage's State (and its Firestore listeners) stays alive in the
    // background instead of being disposed. Falls back to the old
    // push-based navigation if ChatPage is ever used standalone.
    if (widget.onSwitchToMe != null) {
      widget.onSwitchToMe!();
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const MePage()),
    );
  }

  void _goToCommunityPage() {
    searchFocusNode.unfocus();

    // Inside HomeShell this just flips the IndexedStack index -- see
    // the matching comment on _goToMePage above.
    if (widget.onSwitchToCommunity != null) {
      widget.onSwitchToCommunity!();
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CommunityPage()),
    );
  }

  // ==========================================================
  // DELETE CHAT FOR CURRENT USER ONLY
  // ==========================================================

  Future<void> _deleteChatForMe(
    DocumentSnapshot<Map<String, dynamic>> chatDoc,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final chatRef = chatDoc.reference;

    try {
      final messagesSnapshot = await chatRef.collection('messages').get();
      final batch = FirebaseFirestore.instance.batch();

      for (final message in messagesSnapshot.docs) {
        batch.update(message.reference, {
          'hiddenFor': FieldValue.arrayUnion([user.uid]),
        });
      }

      batch.update(chatRef, {
        'hiddenFor': FieldValue.arrayUnion([user.uid]),
      });

      await batch.commit();

      if (!mounted) return;

      showTopAlert(context, 'Chat deleted from your chats');
    } catch (e) {
      debugPrint('Delete chat for me error: $e');

      if (!mounted) return;

      showTopAlert(context, 'Failed to delete chat', isError: true);
    }
  }

  void _showDeleteChatDialog({
    required DocumentSnapshot<Map<String, dynamic>> chatDoc,
    required String otherUserName,
  }) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1B120A),
          title: const Text(
            'Delete Chat',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Delete chat with $otherUserName from your chats?',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text(
                'CANCEL',
                style: TextStyle(color: Color(0xFFD2B48C)),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _deleteChatForMe(chatDoc);
              },
              child: const Text(
                'DELETE',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // MARK A CHAT AS READ (clears the unread dot)
  // ==========================================================

  Future<void> _markChatOpened(String chatId, String otherUid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Per-chat read marker on the chat document itself -- this is
    // what the Nexus Notify unseen-messages reminder
    // (widgets/nexus_notify.dart) reads, and it is written even when
    // the chat has no messages yet.
    unawaited(markChatRead(chatId));

    try {
      final lastMsg = await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('sentAt', descending: true)
          .limit(1)
          .get();

      if (lastMsg.docs.isEmpty) return;

      await lastMsg.docs.first.reference.update({
        'readBy': FieldValue.arrayUnion([user.uid]),
      });
    } catch (e) {
      debugPrint('Mark chat opened error: $e');
    }
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusScope.of(context).unfocus(),
            child: _buildHomePage(),
          ),
        ),
      // Same shared bottom nav widget the Me page uses, so shape, size,
      // corner radius, background, icons, selected state, spacing and
      // the one-shot tap animation are always exactly identical between
      // the two pages (see nexus_bottom_nav.dart).
      bottomNavigationBar: NexusBottomNav(
        selectedIndex: 0,
        onChats: () {}, // already on Chats
        onCommunity: _goToCommunityPage,
        onMe: _goToMePage,
      ),
    );
  }

  // ==========================================================
  // HOME PAGE BODY
  // ==========================================================

  Widget _buildHomePage() {
    final user = FirebaseAuth.instance.currentUser;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ==================================================
          // "Chats" TITLE (glass shimmer) + NOTIFICATION ICON
          // ==================================================
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const _GlassShimmerText(text: 'Chats'),
              const Spacer(),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('connections')
                    .where('receiverUid', isEqualTo: user?.uid)
                    .where('status', isEqualTo: 'pending')
                    .snapshots(),
                builder: (context, snapshot) {
                  final count = snapshot.data?.docs.length ?? 0;

                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        onPressed: _openNotifications,
                        icon: const Icon(
                          Icons.notifications_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      if (count > 0)
                        Positioned(
                          right: 4,
                          top: 2,
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: const BoxDecoration(
                              color: Colors.redAccent,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$count',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 14),

          // ==================================================
          // SEARCH BAR (animated cream focus trace)
          // ==================================================
          _AnimatedTraceBorder(
            controller: _searchBorderController,
            active: searchFocusNode.hasFocus &&
                searchController.text.trim().isNotEmpty,
            radius: 15,
            child: TextField(
              controller: searchController,
              focusNode: searchFocusNode,
              style: const TextStyle(color: Colors.white),
              textInputAction: TextInputAction.search,
              onChanged: _handleSearchChanged,
              onSubmitted: (_) {
                FocusScope.of(context).unfocus();
                if (!chatSearchMode && !searchingUser) {
                  _searchUser();
                }
              },
              decoration: InputDecoration(
                hintText: 'Search Name or Account ID',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: Icon(
                  chatSearchMode
                      ? Icons.manage_search_rounded
                      : Icons.search_rounded,
                  color: const Color(0xFFD2B48C),
                ),
                suffixIcon: _buildSearchSuffixIcon(),
                filled: true,
                fillColor: const Color(0xFF1B120A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // ==================================================
          // SEARCH SUGGESTIONS
          // ==================================================
          _buildSearchSuggestions(user),

          const SizedBox(height: 18),

          // ==================================================
          // PUBLIC / PRIVATE TOGGLE
          // ==================================================
          _PublicPrivateToggle(
            showPrivate: showPrivate,
            onTap: () => setState(() => showPrivate = !showPrivate),
          ),

          const SizedBox(height: 10),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 30),
              child: _buildChats(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchSuffixIcon() {
    if (searchingUser) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFFD2B48C),
          ),
        ),
      );
    }

    if (searchController.text.isNotEmpty) {
      return IconButton(
        onPressed: () {
          searchController.clear();
          _syncSearchBorderAnimation();
        },
        icon: const Icon(Icons.close_rounded, color: Colors.white70),
      );
    }

    // Empty + (possibly) unfocused: Chats icon, darker when
    // Chat Search Mode is active.
    return IconButton(
      onPressed: _toggleChatSearchMode,
      icon: Icon(
        Icons.forum_rounded,
        color: chatSearchMode
            ? const Color(0xFF6B4A2A)
            : const Color(0xFFD2B48C),
      ),
    );
  }

  Widget _buildSearchSuggestions(User? user) {
    final text = searchController.text.trim();

    if (text.isEmpty || user == null) {
      return const SizedBox.shrink();
    }

    // ------------------------------------------------------
    // CHAT MESSAGE SEARCH MODE
    // ------------------------------------------------------
    if (chatSearchMode) {
      if (_messageSearchLoading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: CircularProgressIndicator(color: Color(0xFFD2B48C)),
          ),
        );
      }

      final results = _messageSearchResults(text);

      if (results.isEmpty) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Text(
            'No matching messages',
            style: TextStyle(color: Colors.white54),
          ),
        );
      }

      return _suggestionBox(
        children: results.map((r) {
          return ListTile(
            leading: CircleAvatar(
              radius: 20,
              backgroundColor: const Color(0xFF2A1B0E),
              backgroundImage: _profileImageProvider(r['image'] as String),
              child: (r['image'] as String).isEmpty
                  ? const Icon(Icons.person_rounded, color: Colors.white70)
                  : null,
            ),
            title: Text(
              r['name'] as String,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              r['text'] as String,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54),
            ),
            onTap: () {
              // Opens the matching chat and scrolls straight to the
              // exact message that matched the search, highlighting
              // it briefly so it's clearly visible once in view.
              _openChatFromSearch(
                otherUid: r['otherUid'] as String,
                name: r['name'] as String,
                image: r['image'] as String,
                targetMessageId: r['messageId'] as String,
              );
            },
          );
        }).toList(),
      );
    }

    // ------------------------------------------------------
    // EXACT 10-DIGIT ACCOUNT ID
    // ------------------------------------------------------
    if (text.length == 10) {
      if (searchingUser) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFFD2B48C),
              ),
            ),
          ),
        );
      }

      final data = _accountIdSearchResult;
      if (data == null) return const SizedBox.shrink();

      final docUid = (data['uid'] ?? '').toString();
      final name = (data['publicName'] ?? '').toString();
      final image = (data['publicImage'] ?? '').toString();
      final userId = (data['userId'] ?? '').toString();
      final isConnected = _connectedUids.contains(docUid);

      return _suggestionBox(children: [
        // ==================================================
        // NEW: swipe RIGHT-TO-LEFT on the Account ID suggestion
        // to jump straight into Public Chat with that account.
        // Wrapped in Dismissible purely for its drag/swipe
        // gesture detection — confirmDismiss always returns
        // false so the tile snaps back into place afterwards
        // instead of being removed from the (unrelated) search
        // suggestion list. The normal tap gesture below is
        // completely untouched, so the existing Connect/Profile
        // flow keeps working exactly as before.
        // ==================================================
        Dismissible(
          key: ValueKey('accountIdSuggestion_$docUid'),
          // Swipe LEFT-TO-RIGHT -> straight into Chat.
          // Swipe RIGHT-TO-LEFT -> Public Profile (Connect/Message sheet).
          direction: DismissDirection.horizontal,
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.startToEnd) {
              await _openPublicChatFromAccountSuggestion(
                Map<String, dynamic>.from(data),
              );
            } else if (direction == DismissDirection.endToStart) {
              FocusScope.of(context).unfocus();
              _showSearchResult(Map<String, dynamic>.from(data));
            }
            return false;
          },
          // Revealed while swiping LEFT-TO-RIGHT (startToEnd) -> Chat.
          background: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: const Color(0xFF8B4513),
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Row(
              children: [
                Icon(Icons.chat_bubble_rounded, color: Colors.white),
                SizedBox(width: 8),
                Text(
                  'Chat',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          // Revealed while swiping RIGHT-TO-LEFT (endToStart) -> Public Profile.
          secondaryBackground: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: const Color(0xFF8B4513),
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Profile',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(width: 8),
                Icon(Icons.person_rounded, color: Colors.white),
              ],
            ),
          ),
          child: ListTile(
            leading: CircleAvatar(
              radius: 20,
              backgroundColor: const Color(0xFF2A1B0E),
              backgroundImage: _profileImageProvider(image),
              child: image.isEmpty
                  ? const Icon(Icons.person_rounded, color: Colors.white70)
                  : null,
            ),
            title: Text(
              name.isNotEmpty ? name : 'Unknown User',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              userId,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: isConnected
                ? Container(width: 3, height: 28, color: const Color(0xFF8B4513))
                : null,
            onTap: () {
              FocusScope.of(context).unfocus();
              _showSearchResult(Map<String, dynamic>.from(data));
            },
          ),
        ),
      ]);
    }

    // ------------------------------------------------------
    // NAME MATCH — ONLY within existing Chats
    // ------------------------------------------------------
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();

        final matches =
            _nameSuggestionsFromChats(text, snapshot.data!.docs, user.uid);

        if (matches.isEmpty) return const SizedBox.shrink();

        return _suggestionBox(
          children: matches.map((m) {
            final isConnected = m['isConnected'] as bool;
            final image = (m['displayImage'] ?? '').toString();

            return ListTile(
              leading: CircleAvatar(
                radius: 20,
                backgroundColor: const Color(0xFF2A1B0E),
                backgroundImage: _profileImageProvider(image),
                child: image.isEmpty
                    ? const Icon(Icons.person_rounded, color: Colors.white70)
                    : null,
              ),
              title: Text(
                m['displayName'] as String,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              trailing: isConnected
                  ? Container(width: 3, height: 28, color: const Color(0xFF8B4513))
                  : null,
              onTap: () {
                _openChatFromSearch(
                  otherUid: m['uid'] as String,
                  name: m['displayName'] as String,
                  image: image,
                );
              },
            );
          }).toList(),
        );
      },
    );
  }

  Widget _suggestionBox({required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1B120A),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFFFFDD0).withValues(alpha: 0.25)),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: children.length,
        separatorBuilder: (_, _) =>
            Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
        itemBuilder: (context, index) => children[index],
      ),
    );
  }

  String _activeStatusForUser(Map<String, dynamic> data) {
    final rawEnabled = data['activeInfoEnabled'];
    // Presence visibility is per relationship. The current app stores the
    // viewer's permission in users/{viewer}/chatSettings/{other}. This helper
    // is used only with the already-resolved permission value.
    if (rawEnabled != true) return '';
    if (data['isActive'] == true) return 'Active now';
    final raw = data['lastActiveAt'];
    if (raw is! Timestamp) return '';
    final diff = DateTime.now().difference(raw.toDate());
    if (diff.inMinutes < 1) return 'Active just now';
    if (diff.inMinutes < 60) return 'Active ${diff.inMinutes} min ago';
    if (diff.inHours < 24) return 'Active ${diff.inHours} hr ago';
    return 'Active ${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }

  // NOTE: this used to be a one-shot Future that was cached forever in
  // _nicknameCache. Because ChatPage is kept alive inside HomeShell's
  // IndexedStack (see the class doc comment above), that cache was never
  // invalidated after a nickname was saved from the Chat Screen, so the
  // Chats Page kept showing the old value until the app was restarted.
  // Watching the same ChatSettingsService document that Set Nickname
  // writes to (instead of fetching it once) makes the Chats Page update
  // immediately, with no extra refresh step and no second data source.
  Stream<String> _watchNickname(String otherUid) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return Stream.value('');
    return ChatSettingsService.instance
        .watchSettings(ownerUid: user.uid, otherUid: otherUid)
        .map((data) => (data['nickname'] ?? '').toString().trim());
  }

  // ==========================================================
  // BUILD CHATS (Public / Private filtered list + unread dot)
  // ==========================================================

  Widget _buildChats() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'Unable to load chats',
              style: TextStyle(color: Colors.white54),
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(color: Color(0xFFD2B48C)),
            ),
          );
        }

        if (!snapshot.hasData) return const SizedBox.shrink();

        var chats = snapshot.data!.docs.where((chat) {
          final data = chat.data();
          final hiddenFor = List<String>.from(data['hiddenFor'] ?? []);
          return !hiddenFor.contains(user.uid);
        }).toList();

        // Public / Private split.
        chats = chats.where((chat) {
          final participants =
              List<String>.from(chat.data()['participants'] ?? []);
          final otherUid = participants.firstWhere(
            (id) => id != user.uid,
            orElse: () => '',
          );
          final isConnected = _connectedUids.contains(otherUid);
          return showPrivate ? isConnected : !isConnected;
        }).toList();

        chats.sort((a, b) {
          final aTime = a.data()['lastMessageTime'];
          final bTime = b.data()['lastMessageTime'];
          final aT = aTime is Timestamp ? aTime : null;
          final bT = bTime is Timestamp ? bTime : null;
          if (aT == null && bT == null) return 0;
          if (aT == null) return 1;
          if (bT == null) return -1;
          return bT.compareTo(aT);
        });

        if (chats.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              showPrivate ? 'No connected chats yet' : 'No chats yet',
              style: const TextStyle(color: Colors.white54),
            ),
          );
        }

        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: chats.length,
          separatorBuilder: (_, _) => const SizedBox.shrink(),
          itemBuilder: (context, index) {
            final chatDoc = chats[index];
            final chatData = chatDoc.data();

            final participants =
                List<String>.from(chatData['participants'] ?? []);
            final otherUid = participants.firstWhere(
              (id) => id != user.uid,
              orElse: () => '',
            );

            if (otherUid.isEmpty) return const SizedBox.shrink();

            final isConnected = _connectedUids.contains(otherUid);

            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              // FIX: was FutureBuilder(future: _getUserData(otherUid)),
              // which fetched the other account's profile once and then
              // served the same cached value (_userCache) for the rest
              // of the app session -- so when they changed their private
              // profile name/picture, this chat list tile kept showing
              // the old one until the app was fully closed and reopened
              // (a fresh start clears _userCache). A live snapshots()
              // listener, like the one PrivateChatScreen's own header
              // already uses, keeps this tile in sync immediately.
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(otherUid)
                  .snapshots(),
              builder: (context, userSnapshot) {
                final userData = userSnapshot.data?.data();
                if (userData == null) return const SizedBox.shrink();

                final String name = _resolveDisplayName(
                  userData: userData,
                  isConnected: isConnected,
                );
                final String image = _resolveDisplayImage(
                  userData: userData,
                  isConnected: isConnected,
                );

                return StreamBuilder<String>(
                  stream: _watchNickname(otherUid),
                  builder: (context, nicknameSnapshot) {
                    final nickname = (nicknameSnapshot.data ?? '').trim();
                    final displayName = nickname.isNotEmpty
                        ? '$nickname [$name]'
                        : name;

                    return GestureDetector(
                      onLongPress: () {
                        _showDeleteChatDialog(
                          chatDoc: chatDoc,
                          otherUserName: displayName.isNotEmpty
                              ? displayName
                              : 'Unknown User',
                        );
                      },
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 5),
                        leading: CircleAvatar(
                          radius: 25,
                          backgroundColor: const Color(0xFF2A1B0E),
                          backgroundImage: _profileImageProvider(image),
                          child: image.isEmpty
                              ? const Icon(Icons.person_rounded, color: Colors.white70)
                              : null,
                        ),
                        title: Text(
                          displayName.isNotEmpty ? displayName : 'Unknown User',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: _buildActiveStatusSubtitle(otherUid, isConnected),
                        trailing: _UnreadDot(
                          chatId: chatDoc.id,
                          currentUid: user.uid,
                        ),
                        onTap: () async {
                          searchFocusNode.unfocus();
                          unawaited(_markChatOpened(chatDoc.id, otherUid));

                          // Connected (private) chats route through the
                          // existing PrivateChatScreen entry point -- the
                          // same one used from the connected/private
                          // profile page's "Message" button -- so the
                          // header always shows the private profile name
                          // and picture (live, via its own Firestore
                          // listener) instead of the public profile.
                          // Non-connected (public) chats are completely
                          // unaffected and keep opening the plain
                          // ChatScreen with the public profile as before.
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => isConnected
                                  ? PrivateChatScreen(otherUserUid: otherUid)
                                  : ChatScreen(
                                      otherUserUid: otherUid,
                                      otherUserName: displayName.isNotEmpty
                                          ? displayName
                                          : 'Unknown User',
                                      otherUserImage: image,
                                    ),
                            ),
                          );

                          if (mounted) searchFocusNode.unfocus();
                        },
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildActiveStatusSubtitle(String otherUid, bool isConnected) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();
    // This mirrors ChatScreen's own `activeAllowed` check exactly (see
    // `activeAllowed` in chat_screen.dart): presence is visible here when
    // the two accounts are connected, OR when the OTHER user has opted in
    // to sharing their active status with this viewer. That permission
    // lives in the OTHER user's own chatSettings entry for this viewer
    // (users/{otherUid}/chatSettings/{me}), not in the viewer's own entry
    // -- reading the viewer's own entry (as this previously did) checked
    // the wrong document and made this subtitle stay blank.
    return StreamBuilder<Map<String, dynamic>>(
      stream: ChatSettingsService.instance.watchSettings(
        ownerUid: otherUid,
        otherUid: user.uid,
      ),
      builder: (context, settingsSnapshot) {
        final settings = settingsSnapshot.data ?? const <String, dynamic>{};
        final bool activeAllowed =
            isConnected || settings['activeInfoEnabled'] == true;
        final bool typingAllowed =
            isConnected || settings['typingInfoEnabled'] == true;
        if (!activeAllowed && !typingAllowed) {
          return const SizedBox.shrink();
        }
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance.collection('users').doc(otherUid).snapshots(),
          builder: (context, userSnapshot) {
            final data = userSnapshot.data?.data();
            if (data == null) return const SizedBox.shrink();
            final copy = Map<String, dynamic>.from(data);
            copy['activeInfoEnabled'] = true;
            final label = activeAllowed ? _activeStatusForUser(copy) : '';

            // Same typing-permission + typing-flag check ChatScreen already
            // uses (see `_otherTyping` in chat_screen.dart): typing info is
            // visible here when connected, OR when the other user has opted
            // in to sharing typing info with this viewer -- and only while
            // they're actually typing TO this viewer (`typingToUid`).
            final bool isTyping = typingAllowed &&
                data['isTyping'] == true &&
                (data['typingToUid'] ?? '') == user.uid;

            // While typing, swap the active-status text for "Typing..." in
            // orange. The presence dot itself is left completely alone --
            // it keeps reflecting the real active/offline state either way.
            final displayLabel = isTyping ? 'Typing...' : label;
            if (displayLabel.isEmpty) return const SizedBox.shrink();
            return Row(
              children: [
                PresenceStatusDot(isActive: label == 'Active now'),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isTyping ? Colors.orange : Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ================================================================
// UNREAD DOT
// ----------------------------------------------------------------
// Reads the most recent message in the chat; if it was sent by the
// other participant and the current user hasn't read it yet, shows
// a small cream dot. Disappears automatically once
// _markChatOpened() marks that message as read.
// ================================================================

class _UnreadDot extends StatelessWidget {
  final String chatId;
  final String currentUid;

  const _UnreadDot({required this.chatId, required this.currentUid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('sentAt', descending: true)
          .limit(1)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const SizedBox(width: 10);
        }

        final data = snapshot.data!.docs.first.data();
        final senderId = (data['senderId'] ?? '').toString();
        final readBy = List<String>.from(data['readBy'] ?? []);

        final unread = senderId.isNotEmpty &&
            senderId != currentUid &&
            !readBy.contains(currentUid);

        if (!unread) return const SizedBox(width: 10);

        return Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            color: Color(0xFFFFE9B0),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}

// ================================================================
// GLASS SHIMMER "Chats" TITLE
// ----------------------------------------------------------------
// A soft white highlight sweeps left-to-right across the letters
// on a loop, like light reflecting across glass.
// ================================================================

class _GlassShimmerText extends StatefulWidget {
  final String text;

  const _GlassShimmerText({required this.text});

  @override
  State<_GlassShimmerText> createState() => _GlassShimmerTextState();
}

class _GlassShimmerTextState extends State<_GlassShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;

        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final begin = Alignment(-3 + 6 * t, 0);
            final end = Alignment(-1 + 6 * t, 0);

            return LinearGradient(
              begin: begin,
              end: end,
              colors: const [
                Colors.white,
                Color(0xFFFFFDF0),
                Colors.white,
              ],
              stops: const [0.35, 0.5, 0.65],
            ).createShader(bounds);
          },
          child: Text(
            widget.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.4,
            ),
          ),
        );
      },
    );
  }
}

// ================================================================
// ANIMATED CREAM TRACE BORDER
// ----------------------------------------------------------------
// Shared "comet" outline used by both the search bar (loops while
// focused) and the bottom nav bar (one-shot, on Chats -> Me).
// The trace starts at one point on the border, travels the full
// perimeter, and ends exactly back at that same point.
// ================================================================

class _TraceBorderPainter extends CustomPainter {
  final double progress; // 0..1
  final double radius;
  final Color color;
  final double strokeWidth;
  final double travelFraction;

  _TraceBorderPainter({
    required this.progress,
    required this.radius,
    required this.color,
  }) : strokeWidth = 2.4 , travelFraction = 0.30;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect =
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));

    final path = Path()..addRRect(rrect);

    final metricList = path.computeMetrics().toList();
    if (metricList.isEmpty) return;

    final metric = metricList.first;
    final total = metric.length;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;

    final segLen = total * travelFraction;
    final start = (progress * total) % total;
    final end = start + segLen;

    if (end <= total) {
      canvas.drawPath(metric.extractPath(start, end), paint);
    } else {
      canvas.drawPath(metric.extractPath(start, total), paint);
      canvas.drawPath(metric.extractPath(0, end - total), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TraceBorderPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

/// Wraps [child] with the animated trace border, visible only while
/// [active] is true.
class _AnimatedTraceBorder extends StatelessWidget {
  final AnimationController controller;
  final bool active;
  final double radius;
  final Widget child;

  const _AnimatedTraceBorder({
    required this.controller,
    required this.active,
    required this.radius,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // The trace itself is unchanged (same painter, same radius, same
    // cream color, same looping progress animation). Only how it
    // appears/disappears changed: instead of being added to / removed
    // from the tree instantly via `if (active)` (which also left the
    // controller free to keep looping in the background whenever a
    // caller forgot to call `stop()`), it now always stays mounted and
    // fades its opacity in/out. The controller's play/pause state is
    // owned entirely by the caller (see `_syncSearchBorderAnimation`
    // in chat_page.dart), so when `active` is false the controller is
    // already stopped and this simply fades the frozen frame out.
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              opacity: active ? 1 : 0,
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _TraceBorderPainter(
                      progress: controller.value,
                      radius: radius,
                      color: AppColors.cream,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ================================================================
// PUBLIC / PRIVATE TOGGLE
// ================================================================

class _PublicPrivateToggle extends StatelessWidget {
  final bool showPrivate;
  final VoidCallback onTap;

  const _PublicPrivateToggle({required this.showPrivate, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: showPrivate
              ? const Color(0xFF8B4513).withValues(alpha: 0.35)
              : const Color(0xFF1B120A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFFD2B48C).withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              showPrivate ? Icons.lock_rounded : Icons.public_rounded,
              size: 16,
              color: const Color(0xFFFFE9B0),
            ),
            const SizedBox(width: 8),
            Text(
              showPrivate ? 'Private' : 'Public',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}