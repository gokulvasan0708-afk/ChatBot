import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;

import 'login_page.dart';
import 'chat_page.dart';

class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {

   // ==========================================================
  // MEMBERS
  // ==========================================================

  int membersCount = 0;

  // ==========================================================
  // PUBLIC / PRIVATE
  // ==========================================================

  bool isPublic = true;

  // ==========================================================
  // PUBLIC PROFILE
  // ==========================================================

  String? profileName;
  String? profileImagePath;

  // ==========================================================
  // PRIVATE PROFILE
  // ==========================================================

  static const String cloudName = 'db4zevmud';

  static const String privateUploadPreset =
      'nexus_profile_images';

  final ImagePicker _imagePicker = ImagePicker();

  String? privateName;
  String? privateImage;

  // ==========================================================
  // LOAD PROFILE
  // ==========================================================

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
        // PUBLIC
        profileName = data?['publicName'];
        profileImagePath = data?['publicImage'];

        // PRIVATE
        privateName = data?['privateName'];
        privateImage = data?['privateImage'];

        // MEMBERS
membersCount =
    (data?['membersCount'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      debugPrint(
        'Profile load error: $e',
      );
    }
  }

  // ==========================================================
  // SAVE PRIVATE NAME
  // ==========================================================

  Future<void> _savePrivateName(
    String name,
  ) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(
        {
          'privateName': name,
        },
        SetOptions(merge: true),
      );

      if (!mounted) return;

      setState(() {
        privateName =
            name.trim().isEmpty ? null : name.trim();
      });
    } catch (e) {
      debugPrint(
        'Private name save error: $e',
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Failed to save private name.',
          ),
        ),
      );
    }
  }

  // ==========================================================
  // PICK + UPLOAD PRIVATE PROFILE IMAGE
  // ==========================================================

  Future<void> _pickPrivateProfileImage() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    try {
      final XFile? image =
          await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 800,
        maxHeight: 800,
      );

      if (image == null) return;

      if (!mounted) return;

      // ------------------------------------------------------
      // LOADING
      // ------------------------------------------------------

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) {
          return const Center(
            child: CircularProgressIndicator(
              color: Colors.lightBlueAccent,
            ),
          );
        },
      );

      // ------------------------------------------------------
      // CLOUDINARY REQUEST
      // ------------------------------------------------------

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(
          'https://api.cloudinary.com/v1_1/'
          '$cloudName/image/upload',
        ),
      );

      request.fields['upload_preset'] =
          privateUploadPreset;

      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          image.path,
        ),
      );

      final response = await request.send();

      final responseBody =
          await response.stream.bytesToString();

      // ------------------------------------------------------
      // CLOSE LOADING
      // ------------------------------------------------------

      if (!mounted) return;

      Navigator.of(context).pop();

      // ------------------------------------------------------
      // CHECK CLOUDINARY RESPONSE
      // ------------------------------------------------------

      if (response.statusCode != 200) {
        debugPrint(
          'Cloudinary upload failed: $responseBody',
        );

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Private profile image upload failed.',
            ),
          ),
        );

        return;
      }

      // ------------------------------------------------------
      // GET CLOUDINARY URL
      // ------------------------------------------------------

      final Map<String, dynamic> data =
          jsonDecode(responseBody);

      final String imageUrl =
          (data['secure_url'] ?? '').toString();

      if (imageUrl.isEmpty) {
        throw Exception(
          'Cloudinary URL not received.',
        );
      }

      // ------------------------------------------------------
      // SAVE URL TO FIRESTORE
      // ------------------------------------------------------

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(
        {
          'privateImage': imageUrl,
        },
        SetOptions(merge: true),
      );

      // ------------------------------------------------------
      // UPDATE UI
      // ------------------------------------------------------

      if (!mounted) return;

      setState(() {
        privateImage = imageUrl;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Private profile image updated.',
          ),
        ),
      );
    } catch (e) {
      debugPrint(
        'Private image upload error: $e',
      );

      if (!mounted) return;

      // If loading dialog is still open,
      // safely close it.
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Failed to upload private profile image.',
          ),
        ),
      );
    }
  }

  // ==========================================================
  // LOGOUT
  // ==========================================================

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
          content: Text(
            'Logout failed. Please try again.',
          ),
        ),
      );
    }
  }

  // ==========================================================
  // INIT STATE
  // ==========================================================

  @override
  void initState() {
    super.initState();

    _loadProfile();
  }

  // ==========================================================
  // BUILD
  // ==========================================================

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
          child: _buildMePage(),
        ),
      ),

      // ========================================================
      // BOTTOM NAVIGATION BAR
      // ========================================================

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
                  color:
                      Colors.lightBlueAccent.withValues(
                    alpha: 0.25,
                  ),
                  blurRadius: 15,
                  spreadRadius: 1,
                ),
              ],
            ),

            child: Row(
              mainAxisAlignment:
                  MainAxisAlignment.spaceEvenly,
              children: [

                // ==================================================
                // HOME
                // ==================================================

                GestureDetector(
                  onTap: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const ChatPage(),
                      ),
                    );
                  },

                  child: Container(
                    width: 65,
                    height: 55,
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius:
                          BorderRadius.circular(16),
                    ),

                    child: const Column(
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      children: [

                        Icon(
                          Icons.home_rounded,
                          size: 26,
                          color: Colors.white70,
                        ),

                        SizedBox(height: 3),

                        Text(
                          'Home',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight:
                                FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ==================================================
                // ME
                // ==================================================

                Container(
                  width: 65,
                  height: 55,
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(
                      alpha: 0.25,
                    ),
                    borderRadius:
                        BorderRadius.circular(16),
                  ),

                  child: const Column(
                    mainAxisAlignment:
                        MainAxisAlignment.center,
                    children: [

                      Icon(
                        Icons.person_rounded,
                        size: 26,
                        color: Colors.lightBlueAccent,
                      ),

                      SizedBox(height: 3),

                      Text(
                        'Me',
                        style: TextStyle(
                          color:
                              Colors.lightBlueAccent,
                          fontSize: 11,
                          fontWeight:
                              FontWeight.w600,
                        ),
                      ),
                    ],
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
  // ME PAGE
  // ==========================================================

  Widget _buildMePage() {
    final user =
        FirebaseAuth.instance.currentUser;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,

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
Text(
  isPublic
      ? (profileName != null &&
              profileName!.trim().isNotEmpty
          ? profileName!
          : 'Nexus')
      : (privateName != null &&
              privateName!.trim().isNotEmpty
          ? privateName!
          : 'Nexus'),
  style: const TextStyle(
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
          // PUBLIC / PRIVATE SWITCH
          // ======================================================

          Padding(
            padding: const EdgeInsets.only(
              left: 20,
              top: 5,
            ),

            child: Container(
              height: 30,
              padding: const EdgeInsets.all(1),

              decoration: BoxDecoration(
                color: const Color(0xFF0B1D32),
                borderRadius:
                    BorderRadius.circular(25),
                border: Border.all(
                  color:
                      Colors.lightBlueAccent.withValues(
                    alpha: 0.5,
                  ),
                ),
              ),

              child: Row(
                mainAxisSize:
                    MainAxisSize.min,

                children: [

                  // ==================================================
                  // PUBLIC
                  // ==================================================

                  GestureDetector(
                    onTap: () {
                      setState(() {
                        isPublic = true;
                      });
                    },

                    child: AnimatedContainer(
                      duration:
                          const Duration(
                        milliseconds: 250,
                      ),

                      padding:
                          const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),

                      height: 30,

                      alignment:
                          Alignment.center,

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
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  // ==================================================
                  // PRIVATE
                  // ==================================================

                  GestureDetector(
                    onTap: () {
                      setState(() {
                        isPublic = false;
                      });
                    },

                    child: AnimatedContainer(
                      duration:
                          const Duration(
                        milliseconds: 250,
                      ),

                      padding:
                          const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),

                      height: 30,

                      alignment:
                          Alignment.center,

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
                          fontWeight:
                              FontWeight.bold,
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

  Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: 20,
    ),
    child: Row(
      children: [

        Container(
          width: 75,
          height: 75,
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
                  size: 42,
                ),
        ),

        const SizedBox(width: 15),

        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [

              if (profileName != null &&
                  profileName!.trim().isNotEmpty)
                Text(
                  profileName!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),

              if (user?.email != null) ...[
                const SizedBox(height: 5),

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
        ),
      ],
    ),
  )

else

  _buildPrivateProfile(),

const SizedBox(height: 30),

// ======================================================
// MEMBERS
// ======================================================

_buildMembersSection(),
        ],
      ),
    );
  }

// ==========================================================
// MEMBERS UI
// ==========================================================

Widget _buildMembersSection() {
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: 20,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        // ====================================================
        // MEMBERS HEADER
        // ====================================================

        Row(
          children: [

            const Text(
              'Members',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(width: 10),

            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 9,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(
                  alpha: 0.25,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.lightBlueAccent,
                  width: 1,
                ),
              ),
              child: Text(
                '$membersCount',
                style: const TextStyle(
                  color: Colors.lightBlueAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 15),

        // ====================================================
        // EMPTY MEMBERS
        // ====================================================

        if (membersCount == 0)

          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              vertical: 25,
              horizontal: 15,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF0B1D32),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.lightBlueAccent.withValues(
                  alpha: 0.25,
                ),
              ),
            ),
            child: const Column(
              children: [

                Icon(
                  Icons.people_outline_rounded,
                  color: Colors.white38,
                  size: 40,
                ),

                SizedBox(height: 10),

                Text(
                  'No members yet',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),

                SizedBox(height: 5),

                Text(
                  'Connect with people to add members.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

        // ====================================================
        // MEMBERS WILL COME HERE LATER
        // ====================================================

        if (membersCount > 0)

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: const Color(0xFF0B1D32),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.lightBlueAccent.withValues(
                  alpha: 0.25,
                ),
              ),
            ),
            child: Text(
              '$membersCount member${membersCount == 1 ? '' : 's'}',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
              ),
            ),
          ),
      ],
    ),
  );
}

  // ==========================================================
  // PRIVATE PROFILE UI
  // ==========================================================

Widget _buildPrivateProfile() {
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: 20,
    ),

    child: Row(
      children: [

        // ==============================================
        // PRIVATE PROFILE IMAGE
        // ==============================================

        GestureDetector(
          onTap: _pickPrivateProfileImage,

          child: Container(
            width: 75,
            height: 75,

            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0B1D32),
              border: Border.all(
                color: Colors.lightBlueAccent,
                width: 2,
              ),
            ),

            child: privateImage != null &&
                    privateImage!.isNotEmpty

                ? ClipOval(
                    child: Image.network(
                      privateImage!,
                      width: 75,
                      height: 75,
                      fit: BoxFit.cover,

                      errorBuilder: (
                        context,
                        error,
                        stackTrace,
                      ) {
                        return const Icon(
                          Icons.person_rounded,
                          color: Colors.white70,
                          size: 42,
                        );
                      },
                    ),
                  )

                : const Icon(
                    Icons.person_rounded,
                    color: Colors.white70,
                    size: 42,
                  ),
          ),
        ),

        const SizedBox(width: 15),

        // ==============================================
        // PRIVATE NAME
        // ==============================================

        Expanded(
          child: Text(
            privateName != null &&
                    privateName!.trim().isNotEmpty
                ? privateName!
                : 'Private Profile',

            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    ),
  );
}

  // ==========================================================
  // PRIVATE NAME DIALOG
  // ==========================================================

  void _showPrivateNameDialog(
    TextEditingController controller,
  ) {
    showDialog(
      context: context,

      builder: (context) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF0B1D32),

          title: const Text(
            'Private Name',
            style: TextStyle(
              color: Colors.white,
              fontWeight:
                  FontWeight.bold,
            ),
          ),

          content: TextField(
            controller: controller,

            style: const TextStyle(
              color: Colors.white,
            ),

            decoration:
                InputDecoration(
              hintText:
                  'Enter private name',

              hintStyle:
                  const TextStyle(
                color: Colors.white54,
              ),

              enabledBorder:
                  OutlineInputBorder(
                borderSide:
                    const BorderSide(
                  color:
                      Colors.lightBlueAccent,
                ),
                borderRadius:
                    BorderRadius.circular(
                  12,
                ),
              ),

              focusedBorder:
                  OutlineInputBorder(
                borderSide:
                    const BorderSide(
                  color:
                      Colors.lightBlueAccent,
                  width: 2,
                ),
                borderRadius:
                    BorderRadius.circular(
                  12,
                ),
              ),
            ),
          ),

          actions: [

            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },

              child: const Text(
                'CANCEL',
              ),
            ),

            TextButton(
              onPressed: () async {
                final name =
                    controller.text.trim();

                await _savePrivateName(
                  name,
                );

                if (!context.mounted) {
                  return;
                }

                Navigator.pop(context);
              },

              child: const Text(
                'SAVE',

                style: TextStyle(
                  color:
                      Colors.lightBlueAccent,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // ACCOUNT ID
  // ==========================================================

  Future<void> _showAccountId() async {
    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) return;

    try {
      final doc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();

      if (!doc.exists) return;

      final data = doc.data();

      final String userId =
          (data?['userId'] ?? '')
              .toString();

      if (!mounted) return;

      showDialog(
        context: context,

        builder: (context) {
          return AlertDialog(
            backgroundColor:
                const Color(0xFF0B1D32),

            title: const Text(
              'Your Account ID',
              style: TextStyle(
                color: Colors.white,
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            content: Container(
              width: double.infinity,

              padding:
                  const EdgeInsets.all(15),

              decoration: BoxDecoration(
                color:
                    const Color(0xFF132B45),
                borderRadius:
                    BorderRadius.circular(12),
                border: Border.all(
                  color:
                      Colors.lightBlueAccent,
                ),
              ),

              child: SelectableText(
                userId,

                textAlign:
                    TextAlign.center,

                style: const TextStyle(
                  color:
                      Colors.lightBlueAccent,
                  fontSize: 18,
                  fontWeight:
                      FontWeight.bold,
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
                    color:
                        Colors.lightBlueAccent,
                  ),
                ),
              ),
            ],
          );
        },
      );
    } catch (e) {
      debugPrint(
        'Account ID error: $e',
      );
    }
  }

// ==========================================================
// EDIT PROFILE
// PUBLIC + PRIVATE
// ==========================================================

void _showEditProfile() {
  final nameController = TextEditingController(
    text: isPublic
        ? (profileName ?? '')
        : (privateName ?? ''),
  );

  showModalBottomSheet(
    context: context,

    backgroundColor:
        const Color(0xFF0B1D32),

    shape:
        const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(
        top: Radius.circular(25),
      ),
    ),

    builder: (context) {
      return SafeArea(
        child: Padding(
          padding:
              const EdgeInsets.all(20),

          child: Column(
            mainAxisSize:
                MainAxisSize.min,

            children: [

              // ==================================================
              // TITLE
              // ==================================================

              Text(
                isPublic
                    ? 'Edit Profile'
                    : 'Edit Private Profile',

                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              const SizedBox(height: 20),

              // ==================================================
              // PROFILE IMAGE
              // ==================================================

              Row(
                children: [

                  Expanded(
                    child: ListTile(
                      contentPadding:
                          EdgeInsets.zero,

                      leading:
                          const Icon(
                        Icons.image_rounded,
                        color:
                            Colors.lightBlueAccent,
                      ),

                      title: Text(
                        isPublic
                            ? 'Set Profile Image'
                            : 'Set Private Profile Image',

                        style:
                            const TextStyle(
                          color:
                              Colors.white,
                        ),
                      ),

                      onTap: () {
                        Navigator.pop(
                          context,
                        );

                        if (isPublic) {
                          _showProfileImageOptions();
                        } else {
                          _pickPrivateProfileImage();
                        }
                      },
                    ),
                  ),

                  // ==================================================
                  // REMOVE IMAGE
                  // ==================================================

                  if (
                    isPublic
                        ? profileImagePath != null &&
                          profileImagePath!
                              .trim()
                              .isNotEmpty
                        : privateImage != null &&
                          privateImage!
                              .trim()
                              .isNotEmpty
                  )

                    IconButton(
                      onPressed: () async {

                        final user =
                            FirebaseAuth
                                .instance
                                .currentUser;

                        if (user == null) {
                          return;
                        }

                        try {

                          if (isPublic) {

                            // ========================================
                            // REMOVE PUBLIC IMAGE
                            // ========================================

                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'users',
                                )
                                .doc(user.uid)
                                .update({
                              'publicImage': '',
                            });

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              profileImagePath =
                                  null;
                            });

                          } else {

                            // ========================================
                            // REMOVE PRIVATE IMAGE
                            // ========================================

                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'users',
                                )
                                .doc(user.uid)
                                .update({
                              'privateImage': '',
                            });

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              privateImage =
                                  null;
                            });
                          }

                          Navigator.pop(
                            context,
                          );

                          ScaffoldMessenger
                              .of(context)
                              .showSnackBar(
                            SnackBar(
                              content: Text(
                                isPublic
                                    ? 'Profile image removed.'
                                    : 'Private profile image removed.',
                              ),
                            ),
                          );

                        } catch (e) {

                          debugPrint(
                            'Remove image error: $e',
                          );

                          if (!mounted) {
                            return;
                          }

                          ScaffoldMessenger
                              .of(context)
                              .showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Failed to remove profile image.',
                              ),
                            ),
                          );
                        }
                      },

                      icon:
                          const Icon(
                        Icons
                            .remove_circle_rounded,

                        color:
                            Colors.redAccent,

                        size: 28,
                      ),
                    ),
                ],
              ),

              // ==================================================
              // NAME
              // ==================================================

              Row(
                children: [

                  Expanded(
                    child: ListTile(
                      contentPadding:
                          EdgeInsets.zero,

                      leading:
                          const Icon(
                        Icons.person_rounded,
                        color:
                            Colors.lightBlueAccent,
                      ),

                      title: Text(
                        isPublic
                            ? 'Set / Change Name'
                            : 'Set / Change Private Name',

                        style:
                            const TextStyle(
                          color:
                              Colors.white,
                        ),
                      ),

                      onTap: () {
                        Navigator.pop(
                          context,
                        );

                        if (isPublic) {

                          _showNameDialog(
                            nameController,
                          );

                        } else {

                          _showPrivateNameDialog(
                            nameController,
                          );
                        }
                      },
                    ),
                  ),

                  // ==================================================
                  // REMOVE NAME
                  // ==================================================

                  if (
                    isPublic
                        ? profileName != null &&
                          profileName!
                              .trim()
                              .isNotEmpty
                        : privateName != null &&
                          privateName!
                              .trim()
                              .isNotEmpty
                  )

                    IconButton(
                      onPressed: () async {

                        final user =
                            FirebaseAuth
                                .instance
                                .currentUser;

                        if (user == null) {
                          return;
                        }

                        try {

                          if (isPublic) {

                            // ========================================
                            // REMOVE PUBLIC NAME
                            // ========================================

                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'users',
                                )
                                .doc(user.uid)
                                .update({
                              'publicName': '',
                            });

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              profileName =
                                  null;
                            });

                          } else {

                            // ========================================
                            // REMOVE PRIVATE NAME
                            // ========================================

                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'users',
                                )
                                .doc(user.uid)
                                .update({
                              'privateName': '',
                            });

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              privateName =
                                  null;
                            });
                          }

                          Navigator.pop(
                            context,
                          );

                          ScaffoldMessenger
                              .of(context)
                              .showSnackBar(
                            SnackBar(
                              content: Text(
                                isPublic
                                    ? 'Name removed.'
                                    : 'Private name removed.',
                              ),
                            ),
                          );

                        } catch (e) {

                          debugPrint(
                            'Remove name error: $e',
                          );

                          if (!mounted) {
                            return;
                          }

                          ScaffoldMessenger
                              .of(context)
                              .showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Failed to remove name.',
                              ),
                            ),
                          );
                        }
                      },

                      icon:
                          const Icon(
                        Icons
                            .remove_circle_rounded,

                        color:
                            Colors.redAccent,

                        size: 28,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

  // ==========================================================
  // PUBLIC PROFILE IMAGE OPTIONS
  // ==========================================================

  void _showProfileImageOptions() {
    final List<String> profileImages = [
      'assets/images/profile/profile1.jpg',
      'assets/images/profile/profile2.jpg',
      'assets/images/profile/profile3.jpg',
    ];

    showModalBottomSheet(
      context: context,

      backgroundColor:
          const Color(0xFF0B1D32),

      shape:
          const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(
          top: Radius.circular(25),
        ),
      ),

      builder: (context) {
        return SafeArea(
          child: Padding(
            padding:
                const EdgeInsets.all(20),

            child: Column(
              mainAxisSize:
                  MainAxisSize.min,

              children: [

                const Text(
                  'Choose Profile Image',

                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 20),

                SizedBox(
                  height: 110,

                  child:
                      ListView.separated(
                    scrollDirection:
                        Axis.horizontal,

                    itemCount:
                        profileImages.length,

                    separatorBuilder:
                        (_, _) =>
                            const SizedBox(
                      width: 15,
                    ),

                    itemBuilder:
                        (context, index) {
                      final imagePath =
                          profileImages[index];

                      return GestureDetector(
                        onTap: () async {
                          final user =
                              FirebaseAuth
                                  .instance
                                  .currentUser;

                          if (user == null) {
                            return;
                          }

                          try {
                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'users',
                                )
                                .doc(user.uid)
                                .update({
                              'publicImage':
                                  imagePath,
                            });

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              profileImagePath =
                                  imagePath;
                            });

                            Navigator.pop(
                              context,
                            );
                          } catch (e) {
                            debugPrint(
                              'Profile image save error: $e',
                            );

                            if (!mounted) {
                              return;
                            }

                            ScaffoldMessenger
                                .of(context)
                                .showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Failed to save profile image',
                                ),
                              ),
                            );
                          }
                        },

                        child: Container(
                          width: 90,
                          height: 90,

                          decoration:
                              BoxDecoration(
                            shape:
                                BoxShape.circle,

                            border:
                                Border.all(
                              color:
                                  Colors.lightBlueAccent,
                              width: 2,
                            ),
                          ),

                          child: ClipOval(
                            child:
                                Image.asset(
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
                      color:
                          Colors.redAccent,
                    ),

                    title: const Text(
                      'Remove Profile Image',

                      style: TextStyle(
                        color: Colors.white,
                      ),
                    ),

                    onTap: () async {
                      final user =
                          FirebaseAuth
                              .instance
                              .currentUser;

                      if (user == null) {
                        return;
                      }

                      try {
                        await FirebaseFirestore
                            .instance
                            .collection(
                              'users',
                            )
                            .doc(user.uid)
                            .update({
                          'publicImage': '',
                        });

                        if (!mounted) {
                          return;
                        }

                        setState(() {
                          profileImagePath =
                              null;
                        });

                        Navigator.pop(
                          context,
                        );
                      } catch (e) {
                        debugPrint(
                          'Remove public image error: $e',
                        );
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

  // ==========================================================
  // PUBLIC NAME DIALOG
  // ==========================================================

  void _showNameDialog(
    TextEditingController controller,
  ) {
    showDialog(
      context: context,

      builder: (context) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF0B1D32),

          title: const Text(
            'Set Name',

            style: TextStyle(
              color: Colors.white,
              fontWeight:
                  FontWeight.bold,
            ),
          ),

          content: TextField(
            controller: controller,

            style: const TextStyle(
              color: Colors.white,
            ),

            decoration:
                InputDecoration(
              hintText:
                  'Enter your name',

              hintStyle:
                  const TextStyle(
                color: Colors.white54,
              ),

              enabledBorder:
                  OutlineInputBorder(
                borderSide:
                    const BorderSide(
                  color:
                      Colors.lightBlueAccent,
                ),

                borderRadius:
                    BorderRadius.circular(
                  12,
                ),
              ),

              focusedBorder:
                  OutlineInputBorder(
                borderSide:
                    const BorderSide(
                  color:
                      Colors.lightBlueAccent,
                  width: 2,
                ),

                borderRadius:
                    BorderRadius.circular(
                  12,
                ),
              ),
            ),
          ),

          actions: [

            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },

              child:
                  const Text('CANCEL'),
            ),

            TextButton(
              onPressed: () async {
                final name =
                    controller.text.trim();

                final user =
                    FirebaseAuth
                        .instance
                        .currentUser;

                if (user == null) {
                  return;
                }

                try {
                  await FirebaseFirestore
                      .instance
                      .collection('users')
                      .doc(user.uid)
                      .update({
                    'publicName': name,
                  });

                  if (!mounted) {
                    return;
                  }

                  setState(() {
                    profileName =
                        name.isEmpty
                            ? null
                            : name;
                  });

                  Navigator.pop(context);
                } catch (e) {
                  debugPrint(
                    'Name save error: $e',
                  );

                  if (!mounted) {
                    return;
                  }

                  ScaffoldMessenger
                      .of(context)
                      .showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Failed to save name',
                      ),
                    ),
                  );
                }
              },

              child: const Text(
                'SAVE',

                style: TextStyle(
                  color:
                      Colors.lightBlueAccent,
                  fontWeight:
                      FontWeight.bold,
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

      backgroundColor:
          const Color(0xFF0B1D32),

      shape:
          const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(
          top: Radius.circular(25),
        ),
      ),

      builder: (context) {
        return SafeArea(
          child: Padding(
            padding:
                const EdgeInsets.all(20),

            child: Column(
              mainAxisSize:
                  MainAxisSize.min,

              children: [

                const Text(
                  'Settings',

                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 20),

                ListTile(
                  leading: const Icon(
                    Icons.logout_rounded,
                    color:
                        Colors.redAccent,
                  ),

                  title: const Text(
                    'Logout',

                    style: TextStyle(
                      color: Colors.white,
                      fontWeight:
                          FontWeight.bold,
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
          backgroundColor:
              const Color(0xFF0B1D32),

          title: const Text(
            'Logout',

            style: TextStyle(
              color: Colors.white,
              fontWeight:
                  FontWeight.bold,
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

              child:
                  const Text('CANCEL'),
            ),

            TextButton(
              onPressed: () {
                Navigator.pop(context);

                _logout();
              },

              child: const Text(
                'LOGOUT',

                style: TextStyle(
                  color:
                      Colors.redAccent,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}