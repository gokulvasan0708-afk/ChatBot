import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'login_page.dart';
import 'chat_screen.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selectedIndex = 0;
  bool isPublic = true;

  String? profileName;
  String? profileImagePath;

  final TextEditingController searchController =
    TextEditingController();

bool searchingUser = false;

void _removeSearchFocus() {
  FocusScope.of(context).unfocus();
}

  Future<void> _loadProfile() async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) return;

  try {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    if (!doc.exists) return;

    final data = doc.data();

    if (!mounted) return;

    setState(() {
      profileName = data?['publicName'];
      profileImagePath = data?['publicImage'];
    });
  } catch (e) {
    debugPrint('Profile load error: $e');
  }
}

// ==========================================================
// SEARCH USER BY ACCOUNT ID OR PUBLIC NAME
// ==========================================================

Future<void> _searchUser() async {
  final searchText = searchController.text.trim();

  if (searchText.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Enter Account ID or Public Name'),
      ),
    );
    return;
  }

  setState(() {
    searchingUser = true;
  });

  try {
    // ======================================================
    // SEARCH BY ACCOUNT ID
    // ======================================================

    QuerySnapshot<Map<String, dynamic>> result =
        await FirebaseFirestore.instance
            .collection('users')
            .where(
              'userId',
              isEqualTo: searchText,
            )
            .limit(1)
            .get();

    // ======================================================
    // IF ACCOUNT ID NOT FOUND → SEARCH PUBLIC NAME
    // ======================================================

    if (result.docs.isEmpty) {
      result = await FirebaseFirestore.instance
          .collection('users')
          .where(
            'publicName',
            isEqualTo: searchText,
          )
          .limit(1)
          .get();
    }

    if (!mounted) return;

    setState(() {
      searchingUser = false;
    });

    // ======================================================
    // USER NOT FOUND
    // ======================================================

    if (result.docs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('User not found'),
        ),
      );
      return;
    }

    // ======================================================
    // GET PUBLIC DATA ONLY
    // ======================================================

    final data = result.docs.first.data();

    _showSearchResult(data);
  } catch (e) {
    debugPrint('User search error: $e');

    if (!mounted) return;

    setState(() {
      searchingUser = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Search failed. Please try again.'),
      ),
    );
  }
}

// ==========================================================
// SEARCH SUGGESTIONS
// ==========================================================

Stream<QuerySnapshot<Map<String, dynamic>>> _searchSuggestions() {
  final text = searchController.text.trim();

  // Empty search
  if (text.isEmpty) {
    return FirebaseFirestore.instance
        .collection('users')
        .limit(0)
        .snapshots();
  }

  // ==========================================================
  // ACCOUNT ID SEARCH
  // ==========================================================

  // Only search Account ID when exactly 10 characters
  if (text.length == 10) {
    return FirebaseFirestore.instance
        .collection('users')
        .where(
          'userId',
          isEqualTo: text,
        )
        .limit(1)
        .snapshots();
  }

  // ==========================================================
  // PUBLIC NAME SEARCH
  // ==========================================================

  return FirebaseFirestore.instance
      .collection('users')
      .where(
        'publicName',
        isGreaterThanOrEqualTo: text,
      )
      .where(
        'publicName',
        isLessThan: '$text\uf8ff',
      )
      .limit(8)
      .snapshots();
}

// ==========================================================
// SEARCH RESULT
// ==========================================================

void _showSearchResult(
  Map<String, dynamic> data,
) {
  final String publicName =
      (data['publicName'] ?? '').toString();

  final String publicImage =
      (data['publicImage'] ?? '').toString();

  final String userId =
      (data['userId'] ?? '').toString();

  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF0B1D32),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(25),
      ),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(25),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [

              // PROFILE IMAGE
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF132B45),
                  border: Border.all(
                    color: Colors.lightBlueAccent,
                    width: 2,
                  ),
                ),
                child: publicImage.isNotEmpty
                    ? ClipOval(
                        child: Image.asset(
                          publicImage,
                          fit: BoxFit.cover,
                        ),
                      )
                    : const Icon(
                        Icons.person_rounded,
                        color: Colors.white70,
                        size: 50,
                      ),
              ),

              // PUBLIC NAME
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

              // ACCOUNT ID
              Text(
                userId,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                ),
              ),

              const SizedBox(height: 20),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);

                    // Later:
                    // Connect / Add Friend function
                  },
                  icon: const Icon(
                    Icons.person_add_rounded,
                  ),
                  label: const Text(
                    'CONNECT',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

  Future<void> _logout() async {
  try {
    await FirebaseAuth.instance.signOut();

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => const LoginPage(),
      ),
      (route) => false,
    );
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Logout failed. Please try again.'),
      ),
    );
  }
}

@override
void initState() {
  super.initState();

  _loadProfile();
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020B18),

      body: SafeArea(
  child: GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: () {
      FocusScope.of(context).unfocus();
    },
    child: selectedIndex == 0
        ? _buildHomePage()
        : _buildMePage(),
  ),
),

      // =====================================================
      // BOTTOM NAVIGATION BAR
      // =====================================================

      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(
            left: 25,
            right: 25,
            bottom: 15,
          ),
          child: Container(
            height: 70,
            decoration: BoxDecoration(
              color: const Color(0xFF0B1D32),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: Colors.lightBlueAccent,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.lightBlueAccent.withValues(alpha: 0.25),
                  blurRadius: 15,
                  spreadRadius: 1,
                ),
              ],
            ),

            child: Row(
  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
  children: [

    // HOME
    _buildNavItem(
      icon: Icons.home_rounded,
      label: 'Home',
      index: 0,
    ),

    // ME
    _buildNavItem(
      icon: Icons.person_rounded,
      label: 'Me',
      index: 1,
    ),
  ],
),
          ),
        ),
      ),
    );
  }

// ==========================================================
// HOME PAGE
// ==========================================================

Widget _buildHomePage() {
  return SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(
      20,
      150,
      20,
      30,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        // ==================================================
        // CHATBOT TITLE
        // ==================================================

        Center(
  child: const Text(
    'ChatBot',
    style: TextStyle(
      color: Colors.white,
      fontSize: 30,
      fontWeight: FontWeight.bold,
    ),
  ),
),

        const SizedBox(height: 20),

        Column(
  children: [

    // ==================================================
    // SEARCH BAR
    // ==================================================

    TextField(
      controller: searchController,

      style: const TextStyle(
        color: Colors.white,
      ),

      textInputAction: TextInputAction.search,

      onChanged: (_) {
        setState(() {});
      },

      onSubmitted: (_) {
        FocusScope.of(context).unfocus();
        
        if (!searchingUser) {
          _searchUser();
        }
      },

      decoration: InputDecoration(
        hintText: 'Search Account ID or Public Name',

        hintStyle: const TextStyle(
          color: Colors.white54,
        ),

        prefixIcon: const Icon(
          Icons.search_rounded,
          color: Colors.lightBlueAccent,
        ),

        // ==================================================
        // CLEAR / SEARCH ICON
        // ==================================================

        suffixIcon: searchingUser
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.lightBlueAccent,
                  ),
                ),
              )
            : searchController.text.isNotEmpty
                ? IconButton(
                    onPressed: () {
                      searchController.clear();

                      setState(() {});
                    },
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                    ),
                  )
                : IconButton(
                    onPressed: () {
  FocusScope.of(context).unfocus();
  _searchUser();
},
                    icon: const Icon(
                      Icons.arrow_forward_rounded,
                      color: Colors.lightBlueAccent,
                    ),
                  ),

        filled: true,

        fillColor: const Color(0xFF0B1D32),

        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(
            color: Colors.lightBlueAccent.withValues(
              alpha: 0.5,
            ),
          ),
        ),

        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(
            color: Colors.lightBlueAccent,
            width: 1.5,
          ),
        ),
      ),
    ),

    // ==================================================
    // SEARCH SUGGESTIONS
    // ==================================================

    if (searchController.text.trim().isNotEmpty)
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _searchSuggestions(),

        builder: (context, snapshot) {

          if (!snapshot.hasData ||
              snapshot.data!.docs.isEmpty) {
            return const SizedBox.shrink();
          }

          final users = snapshot.data!.docs;

          return Container(
            margin: const EdgeInsets.only(top: 5),

            decoration: BoxDecoration(
              color: const Color(0xFF0B1D32),

              borderRadius: BorderRadius.circular(15),

              border: Border.all(
                color: Colors.lightBlueAccent.withValues(
                  alpha: 0.3,
                ),
              ),
            ),

            child: ListView.separated(
              shrinkWrap: true,

              physics: const NeverScrollableScrollPhysics(),

              itemCount: users.length,

              separatorBuilder: (_, _) => Divider(
                color: Colors.white.withValues(
                  alpha: 0.08,
                ),
                height: 1,
              ),

              itemBuilder: (context, index) {

                final data = users[index].data();

                final String name =
                    (data['publicName'] ?? '').toString();

                final String image =
                    (data['publicImage'] ?? '').toString();

                final String userId =
                    (data['userId'] ?? '').toString();

                return Dismissible(
  key: ValueKey(
    users[index].id,
  ),

  direction: DismissDirection.startToEnd,

  background: Container(
    alignment: Alignment.centerLeft,

    padding: const EdgeInsets.only(
      left: 20,
    ),

    decoration: BoxDecoration(
      color: Colors.blue,
      borderRadius: BorderRadius.circular(15),
    ),

    child: const Row(
      children: [
        Icon(
          Icons.chat_rounded,
          color: Colors.white,
        ),

        SizedBox(width: 10),

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

  confirmDismiss: (direction) async {
    if (direction == DismissDirection.startToEnd) {
      final data = users[index].data();

      final String uid =
          users[index].id;

      final String name =
          (data['publicName'] ?? '').toString();

      final String image =
          (data['publicImage'] ?? '').toString();

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            otherUserUid: uid,
            otherUserName:
                name.isNotEmpty
                    ? name
                    : 'Unknown User',
            otherUserImage: image,
          ),
        ),
      );
    }

    return false;
  },

  child: ListTile(
    leading: CircleAvatar(
      radius: 22,

      backgroundColor:
          const Color(0xFF132B45),

      backgroundImage:
          image.isNotEmpty
              ? AssetImage(image)
              : null,

      child: image.isEmpty
          ? const Icon(
              Icons.person_rounded,
              color: Colors.white70,
            )
          : null,
    ),

    title: Text(
      name.isNotEmpty
          ? name
          : 'Unknown User',

      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
      ),
    ),

    subtitle: Text(
      userId,

      style: const TextStyle(
        color: Colors.white54,
        fontSize: 12,
      ),
    ),

    trailing: const Icon(
      Icons.arrow_forward_ios_rounded,
      color: Colors.white38,
      size: 16,
    ),

    onTap: () {
      searchController.text = name;

      setState(() {});

      _showSearchResult(data);
    },
  ),
);
              },
            ),
          );
        },
      ),
  ],
),

        // ==================================================
        // HOME CONTENT
        // ==================================================

        const SizedBox(height: 30),

        const Text(
          'Chats',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),

        const SizedBox(height: 10),

        _buildChats(),
      ],
    ),
  );
}

Widget _buildChats() {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) {
    return const SizedBox.shrink();
  }

  return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
    stream: FirebaseFirestore.instance
        .collection('chats')
        .where(
          'participants',
          arrayContains: user.uid,
        )
        .snapshots(),

    builder: (context, snapshot) {
      if (snapshot.hasError) {
        debugPrint(
          'Chats Firestore error: ${snapshot.error}',
        );

        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text(
            'Unable to load chats',
            style: TextStyle(
              color: Colors.white54,
            ),
          ),
        );
      }

      if (snapshot.connectionState ==
          ConnectionState.waiting) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(
              color: Colors.lightBlueAccent,
            ),
          ),
        );
      }

      if (!snapshot.hasData) {
        return const SizedBox.shrink();
      }

      // ======================================================
      // GET CHATS
      // ======================================================

      final chats = snapshot.data!.docs.where((chat) {
        final data = chat.data();

        final hiddenFor = List<String>.from(
          data['hiddenFor'] ?? [],
        );

        return !hiddenFor.contains(user.uid);
      }).toList();

      // ======================================================
      // SORT BY LAST MESSAGE TIME
      // ======================================================

      chats.sort((a, b) {
        final aData = a.data();
        final bData = b.data();

        final Timestamp? aTime =
            aData['lastMessageTime'] is Timestamp
                ? aData['lastMessageTime'] as Timestamp
                : null;

        final Timestamp? bTime =
            bData['lastMessageTime'] is Timestamp
                ? bData['lastMessageTime'] as Timestamp
                : null;

        if (aTime == null && bTime == null) {
          return 0;
        }

        if (aTime == null) {
          return 1;
        }

        if (bTime == null) {
          return -1;
        }

        return bTime.compareTo(aTime);
      });

      // ======================================================
      // NO CHATS
      // ======================================================

      if (chats.isEmpty) {
        return const Padding(
          padding: EdgeInsets.symmetric(
            vertical: 20,
          ),
          child: Text(
            'No chats yet',
            style: TextStyle(
              color: Colors.white54,
            ),
          ),
        );
      }

      // ======================================================
      // CHAT LIST
      // ======================================================

      return ListView.separated(
        shrinkWrap: true,

        physics:
            const NeverScrollableScrollPhysics(),

        itemCount: chats.length,

        separatorBuilder: (_, _) => Divider(
          color: Colors.white.withValues(
            alpha: 0.08,
          ),
        ),

        itemBuilder: (context, index) {
          final chatData =
              chats[index].data();

          final List<dynamic> participants =
              chatData['participants'] ?? [];

          final String otherUid =
              participants.firstWhere(
            (id) => id != user.uid,
            orElse: () => '',
          );

          if (otherUid.isEmpty) {
            return const SizedBox.shrink();
          }

          return FutureBuilder<
              DocumentSnapshot<Map<String, dynamic>>>(
            future: FirebaseFirestore.instance
                .collection('users')
                .doc(otherUid)
                .get(),

            builder: (
              context,
              userSnapshot,
            ) {
              if (userSnapshot.connectionState ==
                  ConnectionState.waiting) {
                return const SizedBox.shrink();
              }

              if (userSnapshot.hasError) {
                debugPrint(
                  'User load error: ${userSnapshot.error}',
                );

                return const SizedBox.shrink();
              }

              if (!userSnapshot.hasData) {
                return const SizedBox.shrink();
              }

              final userData =
                  userSnapshot.data!.data();

              if (userData == null) {
                return const SizedBox.shrink();
              }

              final String name =
                  (userData['publicName'] ?? '')
                      .toString();

              final String image =
                  (userData['publicImage'] ?? '')
                      .toString();

              final String lastMessage =
                  (chatData['lastMessage'] ?? '')
                      .toString();

              // ==================================================
              // CHAT ACCOUNT TILE
              // ==================================================

              return GestureDetector(
                onLongPress: () {
                  _showDeleteChatDialog(
                    chatDoc: chats[index],
                    otherUserName:
                        name.isNotEmpty
                            ? name
                            : 'Unknown User',
                  );
                },

                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(
                    horizontal: 5,
                  ),

                  leading: CircleAvatar(
                    radius: 25,

                    backgroundColor:
                        const Color(0xFF132B45),

                    backgroundImage:
                        image.isNotEmpty
                            ? AssetImage(image)
                            : null,

                    child: image.isEmpty
                        ? const Icon(
                            Icons.person_rounded,
                            color: Colors.white70,
                          )
                        : null,
                  ),

                  title: Text(
                    name.isNotEmpty
                        ? name
                        : 'Unknown User',

                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  subtitle: Text(
                    lastMessage.isNotEmpty
                        ? lastMessage
                        : 'Start chatting',

                    maxLines: 1,

                    overflow:
                        TextOverflow.ellipsis,

                    style: const TextStyle(
                      color: Colors.white54,
                    ),
                  ),

                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white38,
                  ),

                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ChatScreen(
                          otherUserUid:
                              otherUid,

                          otherUserName:
                              name.isNotEmpty
                                  ? name
                                  : 'Unknown User',

                          otherUserImage:
                              image,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      );
    },
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
    // ========================================================
    // GET ALL MESSAGES
    // ========================================================

    final messagesSnapshot =
        await chatRef
            .collection('messages')
            .get();

    final batch =
        FirebaseFirestore.instance.batch();

    // ========================================================
    // HIDE EVERY OLD MESSAGE FOR THIS USER
    //
    // IMPORTANT:
    // We are NOT deleting the messages.
    //
    // So the opposite user can still see them.
    // ========================================================

    for (final message
        in messagesSnapshot.docs) {
      batch.update(
        message.reference,
        {
          'hiddenFor':
              FieldValue.arrayUnion([
            user.uid,
          ]),
        },
      );
    }

    // ========================================================
    // HIDE CHAT FOR CURRENT USER
    // ========================================================

    batch.update(
      chatRef,
      {
        'hiddenFor':
            FieldValue.arrayUnion([
          user.uid,
        ]),
      },
    );

    await batch.commit();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Chat deleted from your chats',
        ),
      ),
    );
  } catch (e) {
    debugPrint(
      'Delete chat for me error: $e',
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Failed to delete chat',
        ),
      ),
    );
  }
}

// ==========================================================
// DELETE CHAT CONFIRMATION
// ==========================================================

void _showDeleteChatDialog({
  required DocumentSnapshot<Map<String, dynamic>> chatDoc,
  required String otherUserName,
}) {
  showDialog(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor:
            const Color(0xFF0B1D32),

        title: const Text(
          'Delete Chat',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),

        content: Text(
          'Delete chat with $otherUserName from your chats?',
          style: const TextStyle(
            color: Colors.white70,
          ),
        ),

        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
            },
            child: const Text(
              'CANCEL',
              style: TextStyle(
                color: Colors.lightBlueAccent,
              ),
            ),
          ),

          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);

              _deleteChatForMe(
                chatDoc,
              );
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
// ME PAGE
// ==========================================================

Widget _buildMePage() {
  final user = FirebaseAuth.instance.currentUser;

  return SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        // ======================================================
        // ME HEADER
        // ======================================================

        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 10,
          ),
          child: Row(
            children: [

              const Text(
                'Me',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const Spacer(),

              // EDIT PROFILE
IconButton(
  onPressed: _showEditProfile,
  icon: const Icon(
    Icons.edit_rounded,
    color: Colors.white,
    size: 25,
  ),
),

// ACCOUNT ID
IconButton(
  onPressed: _showAccountId,
  icon: const Icon(
    Icons.link_rounded,
    color: Colors.white,
    size: 25,
  ),
),

              // SETTINGS
              IconButton(
                onPressed: _showSettings,
                icon: const Icon(
                  Icons.settings_rounded,
                  color: Colors.white,
                  size: 27,
                ),
              ),
            ],
          ),
        ),

        // ======================================================
        // PUBLIC / PRIVATE
        // ======================================================

        Padding(
          padding: const EdgeInsets.only(
            left: 20,
            top: 5,
          ),
          child: Container(
            height: 46,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFF0B1D32),
              borderRadius: BorderRadius.circular(25),
              border: Border.all(
                color: Colors.lightBlueAccent.withValues(
                  alpha: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [

                // PUBLIC
                GestureDetector(
                  onTap: () {
                    setState(() {
                      isPublic = true;
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(
                      milliseconds: 250,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                    ),
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isPublic
                          ? Colors.blue
                          : Colors.transparent,
                      borderRadius:
                          BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Public',
                      style: TextStyle(
                        color: isPublic
                            ? Colors.white
                            : Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),

                // PRIVATE
                GestureDetector(
                  onTap: () {
                    setState(() {
                      isPublic = false;
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(
                      milliseconds: 250,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                    ),
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: !isPublic
                          ? Colors.blue
                          : Colors.transparent,
                      borderRadius:
                          BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Private',
                      style: TextStyle(
                        color: !isPublic
                            ? Colors.white
                            : Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ======================================================
// PROFILE
// ======================================================

const SizedBox(height: 35),

if (isPublic)
  Center(
    child: Column(
      children: [

        // ==================================================
        // PUBLIC PROFILE IMAGE
        // ==================================================

        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF0B1D32),
            border: Border.all(
              color: Colors.lightBlueAccent,
              width: 2,
            ),
          ),
          child: profileImagePath != null &&
                  profileImagePath!.isNotEmpty
              ? ClipOval(
                  child: Image.asset(
                    profileImagePath!,
                    fit: BoxFit.cover,
                  ),
                )
              : const Icon(
                  Icons.person_rounded,
                  color: Colors.white70,
                  size: 55,
                ),
        ),

        // ==================================================
        // PUBLIC NAME
        // ==================================================

        if (profileName != null &&
            profileName!.trim().isNotEmpty) ...[
          const SizedBox(height: 10),

          Text(
            profileName!,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],

        // ==================================================
        // EMAIL
        // ==================================================

        if (user?.email != null) ...[
          const SizedBox(height: 6),

          Text(
            user!.email!,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 13,
            ),
          ),
        ],
      ],
    ),
  )
else
  // ======================================================
  // PRIVATE PAGE
  // ======================================================

  const SizedBox.shrink(),
      ],
    ),
  );
}

// ==========================================================
// SHOW ACCOUNT ID
// ==========================================================

Future<void> _showAccountId() async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) return;

  try {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    if (!doc.exists) return;

    final data = doc.data();

    final String userId =
        (data?['userId'] ?? '').toString();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0B1D32),

          title: const Text(
            'Your Account ID',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),

          content: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: const Color(0xFF132B45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.lightBlueAccent,
              ),
            ),
            child: SelectableText(
              userId,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.lightBlueAccent,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
          ),

          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text(
                'CLOSE',
                style: TextStyle(
                  color: Colors.lightBlueAccent,
                ),
              ),
            ),
          ],
        );
      },
    );
  } catch (e) {
    debugPrint('Account ID error: $e');
  }
}

// ==========================================================
// EDIT PROFILE
// ==========================================================

void _showEditProfile() {
  final nameController = TextEditingController(
    text: profileName ?? '',
  );

  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF0B1D32),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(25),
      ),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [

              const Text(
                'Edit Profile',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 20),

              // PROFILE IMAGE
              ListTile(
                leading: const Icon(
                  Icons.image_rounded,
                  color: Colors.lightBlueAccent,
                ),
                title: const Text(
                  'Set Profile Image',
                  style: TextStyle(
                    color: Colors.white,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);

                  _showProfileImageOptions();
                },
              ),

              // NAME
              ListTile(
                leading: const Icon(
                  Icons.person_rounded,
                  color: Colors.lightBlueAccent,
                ),
                title: const Text(
                  'Set / Change Name',
                  style: TextStyle(
                    color: Colors.white,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);

                  _showNameDialog(nameController);
                },
              ),

              // REMOVE NAME
              if (profileName != null &&
                  profileName!.trim().isNotEmpty)
                ListTile(
                  leading: const Icon(
                    Icons.person_remove_rounded,
                    color: Colors.redAccent,
                  ),
                  title: const Text(
                    'Remove Name',
                    style: TextStyle(
                      color: Colors.white,
                    ),
                  ),
                  onTap: () async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) return;

  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .update({
      'publicName': '',
    });

    if (!mounted) return;

    setState(() {
      profileName = null;
    });

    Navigator.pop(context);
  } catch (e) {
    debugPrint('Remove name error: $e');
  }
},
                ),

              // REMOVE PROFILE IMAGE
              if (profileImagePath != null)
                ListTile(
                  leading: const Icon(
                    Icons.delete_rounded,
                    color: Colors.redAccent,
                  ),
                  title: const Text(
                    'Remove Profile Image',
                    style: TextStyle(
                      color: Colors.white,
                    ),
                  ),
                  onTap: () async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) return;

  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .update({
      'publicImage': '',
    });

    if (!mounted) return;

    setState(() {
      profileImagePath = null;
    });

    Navigator.pop(context);
  } catch (e) {
    debugPrint('Remove image error: $e');
  }
},
                ),
            ],
          ),
        ),
      );
    },
  );
}

void _showProfileImageOptions() {
  final List<String> profileImages = [
    'assets/images/profile/profile1.jpg',
    'assets/images/profile/profile2.jpg',
    'assets/images/profile/profile3.jpg',
  ];

  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF0B1D32),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(25),
      ),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Choose Profile Image',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 20),

              SizedBox(
                height: 110,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: profileImages.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: 15),
                  itemBuilder: (context, index) {
                    final imagePath = profileImages[index];

                    return GestureDetector(
                      onTap: () async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) return;

  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .update({
      'publicImage': imagePath,
    });

    if (!mounted) return;

    setState(() {
      profileImagePath = imagePath;
    });

    Navigator.pop(context);
  } catch (e) {
    debugPrint('Profile image save error: $e');

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Failed to save profile image'),
      ),
    );
  }
},
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.lightBlueAccent,
                            width: 2,
                          ),
                        ),
                        child: ClipOval(
                          child: Image.asset(
                            imagePath,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 15),

              if (profileImagePath != null)
                ListTile(
                  leading: const Icon(
                    Icons.delete_rounded,
                    color: Colors.redAccent,
                  ),
                  title: const Text(
                    'Remove Profile Image',
                    style: TextStyle(
                      color: Colors.white,
                    ),
                  ),
                  onTap: () {
                    setState(() {
                      profileImagePath = null;
                    });

                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
      );
    },
  );
}

void _showNameDialog(
  TextEditingController controller,
) {
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF0B1D32),

        title: const Text(
          'Set Name',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),

        content: TextField(
          controller: controller,
          style: const TextStyle(
            color: Colors.white,
          ),
          decoration: InputDecoration(
            hintText: 'Enter your name',
            hintStyle: const TextStyle(
              color: Colors.white54,
            ),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: Colors.lightBlueAccent,
              ),
              borderRadius:
                  BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: Colors.lightBlueAccent,
                width: 2,
              ),
              borderRadius:
                  BorderRadius.circular(12),
            ),
          ),
        ),

        actions: [

          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('CANCEL'),
          ),

          TextButton(
            onPressed: () async {
  final name = controller.text.trim();

  final user = FirebaseAuth.instance.currentUser;

  if (user == null) return;

  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .update({
      'publicName': name,
    });

    if (!mounted) return;

    setState(() {
      profileName = name.isEmpty ? null : name;
    });

    Navigator.pop(context);
  } catch (e) {
    debugPrint('Name save error: $e');

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Failed to save name'),
      ),
    );
  }
},
            child: const Text(
              'SAVE',
              style: TextStyle(
                color: Colors.lightBlueAccent,
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
// SETTINGS
// ==========================================================

void _showSettings() {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF0B1D32),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(25),
      ),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Settings',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 20),

              ListTile(
                leading: const Icon(
                  Icons.logout_rounded,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'Logout',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showLogoutDialog();
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

// ==========================================================
// LOGOUT CONFIRMATION
// ==========================================================

void _showLogoutDialog() {
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF0B1D32),
        title: const Text(
          'Logout',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: const Text(
          'Are you sure you want to logout?',
          style: TextStyle(
            color: Colors.white70,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('CANCEL'),
          ),

          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _logout();
            },
            child: const Text(
              'LOGOUT',
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
  // NAVIGATION ITEM
  // ==========================================================

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required int index,
  }) {
    final bool isSelected = selectedIndex == index;

    return GestureDetector(
      onTap: () {
        setState(() {
          selectedIndex = index;
        });
      },

      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),

        width: 65,
        height: 55,

        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blue.withValues(alpha: 0.25)
              : Colors.transparent,

          borderRadius: BorderRadius.circular(16),
        ),

        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [

            Icon(
              icon,
              size: 26,
              color: isSelected
                  ? Colors.lightBlueAccent
                  : Colors.white70,
            ),

            const SizedBox(height: 3),

            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? Colors.lightBlueAccent
                    : Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}