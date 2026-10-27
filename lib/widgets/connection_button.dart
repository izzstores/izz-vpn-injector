import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../services/vpn_service.dart';

class ConnectionButton extends StatelessWidget {
  final VpnState state;
  final VoidCallback onTap;

  const ConnectionButton({
    super.key,
    required this.state,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isConnected = state == VpnState.connected;
    final isWorking = state == VpnState.connecting || state == VpnState.authenticating;

    Color buttonColor;
    Color iconColor;
    Color borderColor;

    if (isConnected) {
      buttonColor = AppColors.primary;
      iconColor = Colors.white;
      borderColor = AppColors.primaryDark;
    } else if (isWorking) {
      buttonColor = AppColors.warning;
      iconColor = Colors.white;
      borderColor = AppColors.warning;
    } else {
      buttonColor = AppColors.surface;
      iconColor = AppColors.primary;
      borderColor = AppColors.primary;
    }

    return Center(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(70),
        child: Container(
          width: 130,
          height: 130,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: buttonColor,
            border: Border.all(
              color: borderColor,
              width: 4,
            ),
          ),
          child: Center(
            child: isWorking
                ? const SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(
                      strokeWidth: 4.0,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Icon(
                    Icons.power_settings_new_rounded,
                    size: 56,
                    color: iconColor,
                  ),
          ),
        ),
      ),
    );
  }
}
