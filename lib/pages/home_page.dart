import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ChatBot'),
      ),
      body: const Center(
        child: Text(
          'Welcome to ChatBot',
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}