import 'package:flutter/material.dart';
import '../models/club_model.dart';
import '../../pages/app_theme.dart';

class ClubRulesPage extends StatelessWidget {
  final ClubModel club;
  const ClubRulesPage({super.key, required this.club});
  @override Widget build(BuildContext context) {
    final text = club.rules.trim().isEmpty ? '1. Be respectful to other members.\n\n2. Keep discussions relevant to this club.\n\n3. No harassment, spam, or abusive content.\n\n4. Use spoiler tags when discussing unreleased story details.\n\n5. Follow moderator instructions.' : club.rules.trim();
    final rules = text.split(RegExp(r'\n+')).where((e) => e.trim().isNotEmpty).toList();
    return ListView(padding: const EdgeInsets.fromLTRB(18, 6, 18, 30), children: [
      const Text('Club Rules', style: TextStyle(color:Colors.white,fontSize:22,fontWeight:FontWeight.w800)),
      const SizedBox(height:6),
      const Text('Please follow these rules to keep the club welcoming.', style:TextStyle(color:Colors.white54)),
      const SizedBox(height:16),
      ...rules.asMap().entries.map((entry) => Container(margin:const EdgeInsets.only(bottom:10), padding:const EdgeInsets.all(16), decoration:BoxDecoration(color:const Color(0xFF18181F),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFFA78BFA).withValues(alpha:.2))), child: Row(crossAxisAlignment:CrossAxisAlignment.start, children:[Container(width:28,height:28,alignment:Alignment.center,decoration:const BoxDecoration(shape:BoxShape.circle,gradient:AppColors.goldGradient),child:Text('${entry.key+1}',style:const TextStyle(color:Color(0xFF18181F),fontWeight:FontWeight.w800))),const SizedBox(width:12),Expanded(child:Text(entry.value.replaceFirst(RegExp(r'^\d+[.)]\s*'), ''),style:const TextStyle(color:Colors.white70,height:1.5)))]))),
    ]);
  }
}
