import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'chat_screen.dart';
import 'me_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController searchController =
      TextEditingController();

  bool searchingUser = false;



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
// CONNECT USER
// ==========================================================

Future<void> _connectUser({
  required String otherUserUid,
  required String otherUserName,
}) async {
  final currentUser = FirebaseAuth.instance.currentUser;

  if (currentUser == null) return;

  // Cannot connect with yourself
  if (currentUser.uid == otherUserUid) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('You cannot connect with yourself'),
      ),
    );
    return;
  }

  try {
    // Create a unique connection ID
    final connectionId = [
      currentUser.uid,
      otherUserUid,
    ]..sort();

    final connectionDocId =
        '${connectionId[0]}_${connectionId[1]}';

    await FirebaseFirestore.instance
        .collection('connections')
        .doc(connectionDocId)
        .set({
      'users': [
        currentUser.uid,
        otherUserUid,
      ],
      'status': 'connected',
      'createdAt': FieldValue.serverTimestamp(),
    });

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Connected with $otherUserName',
        ),
      ),
    );
  } catch (e) {
    debugPrint('Connect user error: $e');

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Failed to connect. Please try again.',
        ),
      ),
    );
  }
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

  final String otherUserUid = 
    (data['uid'] ?? '').toString();

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
                onPressed: () async {
  Navigator.pop(context);

  await _connectUser(
    otherUserUid: otherUserUid,
    otherUserName: publicName.isNotEmpty
        ? publicName
        : 'Unknown User',
  );
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
        child: _buildHomePage(),
      ),
    ),

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
              GestureDetector(
                onTap: () {
                  // Already in ChatPage
                },
                child: Container(
                  width: 65,
                  height: 55,
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.home_rounded,
                        size: 26,
                        color: Colors.lightBlueAccent,
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Home',
                        style: TextStyle(
                          color: Colors.lightBlueAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ME
              GestureDetector(
                onTap: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MePage(),
                    ),
                  );
                },
                child: Container(
                  width: 65,
                  height: 55,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.person_rounded,
                        size: 26,
                        color: Colors.white70,
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Me',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
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
        // Nexus TITLE
        // ==================================================

        Center(
  child: const Text(
    'Nexus',
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
}