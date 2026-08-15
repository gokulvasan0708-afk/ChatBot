import 'package:flutter/material.dart';
import 'login_page.dart';

class GetStartedPage extends StatelessWidget {
  const GetStartedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background image
          Positioned.fill(
            child: Image.asset(
              'assets/images/chatbot_start.jpeg',
              fit: BoxFit.cover,
            ),
          ),

          // Get Started button
          Positioned(
            left: 55,
            right: 55,
            bottom: 40,
            child: SizedBox(
              height: 55,
              child: ElevatedButton(
                 style: ElevatedButton.styleFrom(
                 backgroundColor: Colors.blue, // Button colour
                 foregroundColor: Colors.white, // Font colour
                 ),
                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const LoginPage(),
                    ),
                  );
                },
                child: const Text(
                  'LET\'S CHAT',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}