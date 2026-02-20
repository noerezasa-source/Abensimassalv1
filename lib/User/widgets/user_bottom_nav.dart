import 'package:flutter/material.dart';
import '../../helpers/language_helper.dart';

class CustomBottomNav extends StatelessWidget {
  final int currentIndex;
  final Function(int)? onTap;
  final VoidCallback? onAttendanceTap;
  final bool isDarkMode;
  final String attendanceMode;

  const CustomBottomNav({
    super.key,
    required this.currentIndex,
    this.onTap,
    this.onAttendanceTap,
    this.isDarkMode = false,
    this.attendanceMode = 'selfie',
  });

  IconData _getAttendanceIcon() {
    switch (attendanceMode.toLowerCase()) {
      case 'rfid':
        return Icons.copy_all_rounded;
      case 'fingerprint':
        return Icons.fingerprint_rounded;
      case 'face':
        return Icons.face_retouching_natural_rounded;
      case 'selfie':
      default:
        return Icons.camera_alt_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final hasAttendanceButton = onAttendanceTap != null;

    return Container(
      height: 70 + bottomPadding,
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1F0B38) : Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDarkMode ? 0.3 : 0.05),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Navigation Items
          Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: 8 + bottomPadding,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(
                  context,
                  Icons.home_rounded,
                  AppLanguage.tr('home'),
                  0,
                ),
                if (hasAttendanceButton) const SizedBox(width: 80),
                _buildNavItem(
                  context,
                  Icons.person_rounded,
                  AppLanguage.tr('profile'),
                  1,
                ),
              ],
            ),
          ),
          // Floating Attendance Button
          if (hasAttendanceButton)
            Positioned(
              left: MediaQuery.of(context).size.width / 2 - 35,
              top: -32,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onAttendanceTap,
                  borderRadius: BorderRadius.circular(35),
                  child: Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      color: isDarkMode
                          ? const Color(0xFF9E77F1)
                          : const Color(0xFF4A1E79),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDarkMode
                            ? const Color(0xFF1F0B38)
                            : Colors.white,
                        width: 5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              (isDarkMode
                                      ? const Color(0xFF9E77F1)
                                      : const Color(0xFF4A1E79))
                                  .withValues(alpha: isDarkMode ? 0.3 : 0.4),
                          blurRadius: 15,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      _getAttendanceIcon(),
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    IconData icon,
    String label,
    int index,
  ) {
    final isSelected = currentIndex == index;
    final accentColor = isDarkMode
        ? const Color(0xFFD0BCFF)
        : const Color(0xFF4A1E79);

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onTap?.call(index),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Indicator Line
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 3,
                width: isSelected ? 24 : 0,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              Icon(
                icon,
                color: isSelected
                    ? accentColor
                    : (isDarkMode ? Colors.white54 : Colors.grey.shade600),
                size: 26,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: isSelected
                      ? accentColor
                      : (isDarkMode ? Colors.white54 : Colors.grey.shade600),
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
