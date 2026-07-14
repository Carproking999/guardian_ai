import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class WelcomeRobotScreen extends StatefulWidget {
  final VoidCallback onFinished;
  const WelcomeRobotScreen({super.key, required this.onFinished});

  @override
  State<WelcomeRobotScreen> createState() => _WelcomeRobotScreenState();
}

class _WelcomeRobotScreenState extends State<WelcomeRobotScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) widget.onFinished();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Lottie.network(
              'https://assets9.lottiefiles.com/packages/lf20_touohxv0.json',
              width: 220,
              height: 220,
              repeat: false,
            ),
            const SizedBox(height: 16),
            const Text(
              "Aapka swagat hai",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}
