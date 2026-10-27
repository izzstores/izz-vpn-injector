import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/vpn_service.dart';

class ConnectionButton extends StatefulWidget {
  final VpnState state;
  final VoidCallback onTap;

  const ConnectionButton({
    super.key,
    required this.state,
    required this.onTap,
  });

  @override
  State<ConnectionButton> createState() => _ConnectionButtonState();
}

class _ConnectionButtonState extends State<ConnectionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = widget.state == VpnState.connected;
    final isWorking = widget.state == VpnState.connecting ||
        widget.state == VpnState.authenticating;

    return Center(
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            final scale = (isConnected || isWorking) ? _pulseAnimation.value : 1.0;
            return Transform.scale(
              scale: scale,
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: isConnected
                      ? AppColors.connectedGradient
                      : isWorking
                          ? const LinearGradient(
                              colors: [AppColors.warning, AppColors.cyan],
                            )
                          : AppColors.primaryGradient,
                  boxShadow: [
                    BoxShadow(
                      color: isConnected
                          ? AppColors.success.withOpacity(0.5)
                          : isWorking
                              ? AppColors.warning.withOpacity(0.4)
                              : AppColors.cyan.withOpacity(0.35),
                      blurRadius: (isConnected || isWorking) ? 35 : 20,
                      spreadRadius: (isConnected || isWorking) ? 6 : 2,
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.surface,
                    ),
                    child: Center(
                      child: isWorking
                          ? const SizedBox(
                              width: 50,
                              height: 50,
                              child: CircularProgressIndicator(
                                strokeWidth: 4.0,
                                valueColor: AlwaysStoppedAnimation<Color>(AppColors.cyan),
                              ),
                            )
                          : Icon(
                              Icons.power_settings_new_rounded,
                              size: 58,
                              color: isConnected
                                  ? AppColors.success
                                  : AppColors.cyan,
                            ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
