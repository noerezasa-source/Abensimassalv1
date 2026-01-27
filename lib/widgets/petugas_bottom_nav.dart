import 'package:flutter/material.dart';

class PetugasBottomNav extends StatelessWidget {
  final int currentIndex;
  final Function(int) onNavigationTap;
  final VoidCallback? onAttendanceTap; // Opsional - null jika tidak ada tombol attendance

  const PetugasBottomNav({
    super.key,
    required this.currentIndex,
    required this.onNavigationTap,
    this.onAttendanceTap, // Opsional
  });

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final hasAttendanceButton = onAttendanceTap != null;

    return Container(
      height: 70 + bottomPadding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Bottom Navigation Items
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
                  'Home',
                  0,
                ),
                _buildNavItem(
                  context,
                  Icons.people_rounded,
                  'Member',
                  1,
                ),
                // Spacer untuk tombol attendance di tengah (hanya jika ada)
                if (hasAttendanceButton) const SizedBox(width: 80),
                _buildNavItem(
                  context,
                  Icons.list_alt_rounded,
                  'Records',
                  2,
                ),
                _buildNavItem(
                  context,
                  Icons.person_rounded,
                  'Profile',
                  3,
                ),
              ],
            ),
          ),
          // Attendance Button di tengah yang timbul (hanya jika onAttendanceTap != null)
          if (hasAttendanceButton)
            Positioned(
              left: MediaQuery.of(context).size.width / 2 - 32,
              top: -28,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onAttendanceTap,
                  borderRadius: BorderRadius.circular(32),
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF9333EA), Color(0xFF7C3AED)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white,
                        width: 4,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF9333EA).withValues(alpha: 0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.face_retouching_natural_rounded,
                      color: Colors.white,
                      size: 28,
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
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onNavigationTap(index),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF9333EA).withValues(alpha: 0.1)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    color: isSelected
                        ? const Color(0xFF9333EA)
                        : Colors.grey.shade600,
                    size: 22,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 9,
                    color: isSelected
                        ? const Color(0xFF9333EA)
                        : Colors.grey.shade600,
                    fontWeight:
                        isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}