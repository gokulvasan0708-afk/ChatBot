import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'community_post_card.dart';
import '../services/community_feed_service.dart';
import '../services/community_service.dart';
import '../widgets/community_widgets.dart';

// ================================================================
// COMMUNITY POST DETAIL
// ----------------------------------------------------------------
// A single feed post on its own screen (opened from Community
// Search results). Uses the same CommunityPostCard as the Feed, so
// reactions, comments, share, save, report, edit, delete and pin all
// behave identically. The post is streamed live: if it is deleted
// while open, the screen says so instead of crashing.
// ================================================================
class CommunityPostDetailPage extends StatelessWidget {
  final String postId;
  final String communityDocId;

  const CommunityPostDetailPage({
    super.key,
    required this.postId,
    required this.communityDocId,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Post', style: TextStyle(color: Colors.white)),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: CommunityService.watchCommunity(communityDocId),
        builder: (context, communitySnap) {
          if (communitySnap.connectionState == ConnectionState.waiting) {
            return const CommunityLoading();
          }
          final community = communitySnap.data?.data();
          if (community == null) {
            return const CommunityStateMessage(
              icon: Icons.public_off_rounded,
              title: 'Community not found',
              subtitle: 'This community may have been deleted.',
            );
          }

          return StreamBuilder<Map<String, dynamic>?>(
            stream: CommunityFeedService.watchPost(postId),
            builder: (context, postSnap) {
              if (postSnap.connectionState == ConnectionState.waiting) {
                return const CommunityLoading();
              }
              if (postSnap.hasError) {
                return const CommunityStateMessage(
                  icon: Icons.error_outline_rounded,
                  title: 'Unable to load this post',
                  subtitle: 'Check your connection and try again.',
                );
              }
              final post = postSnap.data;
              if (post == null) {
                return const CommunityStateMessage(
                  icon: Icons.delete_outline_rounded,
                  title: 'Post not available',
                  subtitle: 'This post was deleted.',
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  CommunityPostCard(
                    post: post,
                    community: community,
                    communityName: (community['name'] ?? '').toString(),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
