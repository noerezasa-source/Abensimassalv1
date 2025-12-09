// lib/widgets/mode_confirmation_dialog.dart
import 'package:flutter/material.dart';

class ModeConfirmationDialog extends StatelessWidget {
  final String currentMode;
  final String newMode;
  final VoidCallback onConfirm;

  const ModeConfirmationDialog({
    super.key,
    required this.currentMode,
    required this.newMode,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final isCheckIn = newMode == 'check_in';
    final color = isCheckIn ? Colors.green : Colors.red;
    final icon = isCheckIn ? Icons.login : Icons.logout;
    final label = isCheckIn ? 'Check In' : 'Check Out';

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withValues(alpha: 0.1),
              Colors.white,
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 40,
                color: color,
              ),
            ),
            const SizedBox(height: 20),
            
            // Message
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.grey.shade700,
                  height: 1.4,
                ),
                children: [
                  const TextSpan(text: 'Anda akan mengubah mode menjadi\n'),
                  TextSpan(
                    text: label,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: color,
                      fontSize: 18,
                    ),
                  ),
                  const TextSpan(text: '\n\n'),
                  const TextSpan(
                    text: 'Pilih mode waktu:',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // Mode Selection Buttons
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      Navigator.of(context).pop(true);
                      onConfirm();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.work,
                            color: Colors.blue.shade600,
                            size: 24,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Waktu Kerja',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      Navigator.of(context).pop(true);
                      onConfirm();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange.shade200),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.free_breakfast,
                            color: Colors.orange.shade600,
                            size: 24,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Waktu Istirahat',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Future<bool?> show({
    required BuildContext context,
    required String currentMode,
    required String newMode,
    required VoidCallback onConfirm,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ModeConfirmationDialog(
        currentMode: currentMode,
        newMode: newMode,
        onConfirm: onConfirm,
      ),
    );
  }
}