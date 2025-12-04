import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/attendance_record.dart';
import '../services/attendance_service.dart';
import '../helpers/timezone_helper.dart';
import '../helpers/sound_helper.dart';
import 'manual_check_page.dart';

class RfidAttendancePage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const RfidAttendancePage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
  });

  @override
  State<RfidAttendancePage> createState() => _RfidAttendancePageState();
}

class _RfidAttendancePageState extends State<RfidAttendancePage> {
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseClient _supabase = Supabase.instance.client;

  final TextEditingController _cardController = TextEditingController();
  final FocusNode _cardFocusNode = FocusNode();
  Timer? _clockTimer;

  final List<_AttendanceEntry> _entries = [];
  String _organizationTimezone = 'Asia/Jakarta'; // Default timezone
  String _organizationName = ''; // Organization name
  String _attendanceMode = 'check_in'; // 'check_in', 'check_out'
  DateTime _currentTime = DateTime.now();
  
  // Work time / Break time
  String? _workTimeMode; // 'work_time', 'break_time', or null for auto
  Map<String, dynamic>? _memberSchedule;
  Timer? _scheduleCheckTimer;

  int? get _organizationId =>
      widget.memberData['organization_id'] as int?;

  /// Get filtered entries based on current mode
  List<_AttendanceEntry> get _filteredEntries {
    return _entries.where((entry) => entry.action == _attendanceMode).toList();
  }

  @override
  void initState() {
    super.initState();
    _loadOrganizationData();
    _loadMemberSchedule();
    _startClock();
    _startScheduleCheck();
    // Delay focus request to avoid keyboard auto-opening
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _cardFocusNode.requestFocus();
        }
      });
    });
  }

  void _startClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentTime = DateTime.now();
        });
      } else {
        timer.cancel();
      }
    });
  }

  void _startScheduleCheck() {
    _scheduleCheckTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (mounted && _workTimeMode == null) {
        // Only auto-update if not manually set
        setState(() {
          // Trigger rebuild to update work time/break time display
        });
      }
    });
  }

  Future<void> _loadMemberSchedule() async {
    try {
      final today = DateTime.now();
      final todayStr = today.toIso8601String().split('T')[0];
      
      // Get member schedule
      final schedule = await _supabase
          .from('member_schedules')
          .select('''
            id,
            work_schedule_id,
            shift_id,
            effective_date,
            end_date
          ''')
          .eq('organization_member_id', widget.organizationMemberId)
          .eq('is_active', true)
          .lte('effective_date', todayStr)
          .or('end_date.is.null,end_date.gte.$todayStr')
          .order('effective_date', ascending: false)
          .limit(1)
          .maybeSingle();

      if (schedule != null) {
        final workScheduleId = schedule['work_schedule_id'] as int?;
        final shiftId = schedule['shift_id'] as int?;
        
        Map<String, dynamic>? scheduleData;
        
        if (shiftId != null) {
          // Get shift details
          final shift = await _supabase
              .from('shifts')
              .select('id, start_time, end_time')
              .eq('id', shiftId)
              .maybeSingle();
          
          if (shift != null) {
            scheduleData = {
              'type': 'shift',
              'shift': shift,
            };
          }
        } else if (workScheduleId != null) {
          // Get work schedule details for today
          final dayOfWeek = today.weekday % 7; // 0 = Sunday, 1 = Monday, ..., 6 = Saturday
          
          final workScheduleDetail = await _supabase
              .from('work_schedule_details')
              .select('day_of_week, start_time, end_time, break_start, break_end')
              .eq('work_schedule_id', workScheduleId)
              .eq('day_of_week', dayOfWeek)
              .maybeSingle();
          
          if (workScheduleDetail != null) {
            scheduleData = {
              'type': 'work_schedule',
              'detail': workScheduleDetail,
            };
          }
        }
        
        if (scheduleData != null) {
          final combinedSchedule = Map<String, dynamic>.from(schedule)
            ..addAll(scheduleData);
          setState(() {
            _memberSchedule = combinedSchedule;
          });
          debugPrint('Member schedule loaded');
        }
      }
    } catch (e) {
      debugPrint('Error loading member schedule: $e');
    }
  }

  String _getWorkTimeMode() {
    // If manually set, return that
    if (_workTimeMode != null) {
      return _workTimeMode!;
    }

    // Auto-determine based on schedule
    if (_memberSchedule == null) {
      return 'work_time'; // Default to work time
    }

    final orgTime = TimezoneHelper.convertUtcToOrgTimezone(
      _currentTime.toUtc(),
      _organizationTimezone,
    );
    
    final currentTimeOfDay = TimeOfDay.fromDateTime(orgTime);
    final currentMinutes = currentTimeOfDay.hour * 60 + currentTimeOfDay.minute;

    // Check if member has shift or work schedule
    final scheduleType = _memberSchedule!['type'] as String?;
    
    if (scheduleType == 'shift') {
      // Use shift timing
      final shift = _memberSchedule!['shift'] as Map<String, dynamic>?;
      if (shift != null) {
        final startTimeStr = shift['start_time'] as String?;
        final endTimeStr = shift['end_time'] as String?;
        
        if (startTimeStr != null && endTimeStr != null) {
          final startTime = _parseTimeString(startTimeStr);
          final endTime = _parseTimeString(endTimeStr);
          
          if (startTime != null && endTime != null) {
            final startMinutes = startTime.hour * 60 + startTime.minute;
            final endMinutes = endTime.hour * 60 + endTime.minute;
            
            // Simple logic: if within shift time, it's work time
            if (currentMinutes >= startMinutes && currentMinutes < endMinutes) {
              return 'work_time';
            }
          }
        }
      }
    } else if (scheduleType == 'work_schedule') {
      // Use work schedule details
      final detail = _memberSchedule!['detail'] as Map<String, dynamic>?;
      if (detail != null) {
        final breakStartStr = detail['break_start'] as String?;
        final breakEndStr = detail['break_end'] as String?;
        final startTimeStr = detail['start_time'] as String?;
        
        if (breakStartStr != null && breakEndStr != null && startTimeStr != null) {
          final startTime = _parseTimeString(startTimeStr);
          final breakStart = _parseTimeString(breakStartStr);
          final breakEnd = _parseTimeString(breakEndStr);
          
          if (startTime != null && breakStart != null && breakEnd != null) {
            final startMinutes = startTime.hour * 60 + startTime.minute;
            final breakStartMinutes = breakStart.hour * 60 + breakStart.minute;
            final breakEndMinutes = breakEnd.hour * 60 + breakEnd.minute;
            
            // If current time >= start_time and < break_start: work time
            // If current time >= break_start and < break_end: break time
            // If current time >= break_end: work time
            if (currentMinutes >= startMinutes && currentMinutes < breakStartMinutes) {
              return 'work_time';
            } else if (currentMinutes >= breakStartMinutes && currentMinutes < breakEndMinutes) {
              return 'break_time';
            } else if (currentMinutes >= breakEndMinutes) {
              return 'work_time';
            }
          }
        }
      }
    }

    return 'work_time'; // Default
  }

  TimeOfDay? _parseTimeString(String timeStr) {
    try {
      final parts = timeStr.split(':');
      if (parts.length >= 2) {
        final hour = int.parse(parts[0]);
        final minute = int.parse(parts[1]);
        return TimeOfDay(hour: hour, minute: minute);
      }
    } catch (e) {
      debugPrint('Error parsing time string: $timeStr, error: $e');
    }
    return null;
  }

  Future<void> _loadOrganizationData() async {
    final organizationId = _organizationId;
    if (organizationId == null) return;

    try {
      final org = await _supabase
          .from('organizations')
          .select('timezone, name')
          .eq('id', organizationId)
          .maybeSingle();

      if (org != null) {
        setState(() {
          if (org['timezone'] != null) {
            _organizationTimezone = org['timezone'] as String;
          }
          if (org['name'] != null) {
            _organizationName = org['name'] as String;
          }
        });
        debugPrint('Organization data loaded: $_organizationName ($_organizationTimezone)');
      }
    } catch (e) {
      debugPrint('Error loading organization data: $e');
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _scheduleCheckTimer?.cancel();
    _cardController.dispose();
    _cardFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(
          _organizationName.isEmpty ? 'RFID Attendance Mode' : _organizationName,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        titleSpacing: 8,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF6B46C1), Color(0xFF9333EA)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        leadingWidth: 40,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_note),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ManualCheckPage(
                    organizationMemberId: widget.organizationMemberId,
                    memberData: widget.memberData,
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showMenu(context),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => _cardFocusNode.requestFocus(),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // Clock and Mode Switcher Card
              _buildClockAndModeCard(),
              const SizedBox(height: 16),
              // Hidden field untuk menangkap input dari scanner
              Offstage(
                offstage: true,
                child: TextField(
                  controller: _cardController,
                  focusNode: _cardFocusNode,
                  showCursor: false,
                  enableInteractiveSelection: false,
                  decoration: const InputDecoration(border: InputBorder.none),
                  onSubmitted: (_) => _handleCardScan(),
                ),
              ),
              Expanded(
                child: _filteredEntries.isEmpty
                    ? Center(
                        child: Text(
                          'Scan card in here',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.separated(
                        itemCount: _filteredEntries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (_, index) =>
                            _buildEntryCard(_filteredEntries[index]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClockAndModeCard() {
    // Convert current time to organization timezone
    final orgTime = TimezoneHelper.convertUtcToOrgTimezone(
      _currentTime.toUtc(),
      _organizationTimezone,
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 20,
            offset: const Offset(0, 8),
            spreadRadius: 2,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Clock Section
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatDateTime(orgTime),
                  style: const TextStyle(
                    fontSize: 42,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF9333EA),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatDate(orgTime),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          // Mode Switcher Toggle
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _getWorkTimeMode() == 'break_time' ? 'Break time' : 'Work time',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildToggleButton('In', 'check_in'),
                    _buildToggleButton('Out', 'check_out'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToggleButton(String label, String mode) {
    final isSelected = _attendanceMode == mode;
    Color buttonColor;
    
    if (mode == 'check_in') {
      buttonColor = Colors.green;
    } else {
      buttonColor = Colors.red;
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _attendanceMode = mode;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? buttonColor : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.white : Colors.grey.shade700,
          ),
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _findMemberByCard(String cardNumber) async {
    final orgId = _organizationId;
    if (orgId == null) return null;

    try {
      final cardData = await _supabase
          .from('rfid_cards')
          .select('''
          id,
          card_number,
          organization_member_id,
          organization_members!inner(
            id,
            organization_id,
            user_id,
            department_id,
            user_profiles (
              display_name,
              first_name,
              last_name,
              profile_photo_url
            )
          )
        ''')
          .eq('card_number', cardNumber)
          .eq('organization_members.organization_id', orgId)
          .eq('is_active', true)
          .maybeSingle();
      
      if (cardData == null) return null;
      
      // Get department separately to avoid relationship ambiguity
      final memberInfo = cardData['organization_members'] as Map<String, dynamic>? ?? {};
      final departmentId = memberInfo['department_id'] as int?;
      
      if (departmentId != null) {
        try {
          final departmentData = await _supabase
              .from('departments')
              .select('id, name')
              .eq('id', departmentId)
              .maybeSingle();
          
          if (departmentData != null) {
            memberInfo['department'] = departmentData;
          }
        } catch (e) {
          debugPrint('Error loading department: $e');
        }
      }
      
      return cardData;
    } catch (e) {
      debugPrint('Error finding member by card: $e');
      return null;
    }
  }

  Future<void> _handleCardScan() async {
    final cardNumber = _cardController.text.trim();
    if (cardNumber.isEmpty) {
      return;
    }

    try {
      final cardData = await _findMemberByCard(cardNumber);
      if (cardData == null) return;

      final memberInfo =
          cardData['organization_members'] as Map<String, dynamic>? ?? {};
      final memberId =
          cardData['organization_member_id'] as int? ?? memberInfo['id'] as int?;

      if (memberId == null) return;

      // Verify that the member belongs to the current organization
      final memberOrgId = memberInfo['organization_id'] as int?;
      if (memberOrgId != _organizationId) {
        debugPrint('Member belongs to different organization: $memberOrgId vs $_organizationId');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kartu RFID tidak terdaftar di organisasi ini'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      AttendanceRecord record;
      String action;
      
      if (_attendanceMode == 'check_in') {
        // Force check in mode
        record = await _attendanceService.checkIn(
          organizationMemberId: memberId,
          photoUrl: '',
          method: 'rfid_card_mobile',
          organizationTimezone: _organizationTimezone,
          rawData: {
            'card_number': cardNumber,
            'scanned_by_member_id': widget.organizationMemberId,
          },
        );
        action = 'check_in';
      } else {
        // Force check out mode
        record = await _attendanceService.checkOut(
          organizationMemberId: memberId,
          photoUrl: '',
          method: 'rfid_card_mobile',
          organizationTimezone: _organizationTimezone,
          rawData: {
            'card_number': cardNumber,
            'scanned_by_member_id': widget.organizationMemberId,
          },
        );
        action = 'check_out';
      }

      // Play success sound
      await SoundHelper.playSuccessSound();

      if (!mounted) return;
      setState(() {
        final existingIndex =
            _entries.indexWhere((entry) => entry.memberId == memberId);
        final newEntry = _AttendanceEntry(
          memberId: memberId,
          memberInfo: memberInfo,
          attendance: record,
          cardNumber: cardNumber,
          action: action,
          timestamp: DateTime.now(),
        );

        if (existingIndex >= 0) {
          _entries.removeAt(existingIndex);
        }
        _entries.insert(0, newEntry);
      });
    } catch (e) {
      debugPrint('Error handling card scan: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      _cardController.clear();
      _cardFocusNode.requestFocus();
    }
  }

  Widget _buildEntryCard(_AttendanceEntry entry) {
    final memberName = _composeMemberName(entry.memberInfo);
    final profile =
        entry.memberInfo['user_profiles'] as Map<String, dynamic>? ?? {};
    final photoPath = profile['profile_photo_url'] as String?;
    
    // ✅ PERBAIKAN: Gunakan 'department' (singular) bukan 'departments'
    final department = entry.memberInfo['department'] as Map<String, dynamic>?;
    final departmentName = department?['name'] as String? ?? '-';

    ImageProvider? imageProvider;
    if (photoPath != null && photoPath.trim().isNotEmpty) {
      if (photoPath.startsWith('http')) {
        imageProvider = NetworkImage(photoPath);
      } else {
        imageProvider = NetworkImage(
          _supabase.storage
              .from('profile-photos')
              .getPublicUrl('mass-profile/$photoPath'),
        );
      }
    }

    final isCheckIn = entry.action == 'check_in';
    final isCheckOut = entry.action == 'check_out';

    // Convert UTC timestamps to organization timezone
    final checkInTime = entry.attendance.actualCheckIn != null
        ? TimezoneHelper.convertUtcToOrgTimezone(
            entry.attendance.actualCheckIn!,
            _organizationTimezone,
          )
        : null;

    final checkOutTime = entry.attendance.actualCheckOut != null
        ? TimezoneHelper.convertUtcToOrgTimezone(
            entry.attendance.actualCheckOut!,
            _organizationTimezone,
          )
        : null;

    // Get the relevant time based on mode
    final displayTime = _attendanceMode == 'check_in' ? checkInTime : checkOutTime;
    final timeString = _formatTime(displayTime);
    
    // Get work time mode for display
    final workTimeMode = _getWorkTimeMode();
    final modePrefix = workTimeMode == 'break_time' ? 'Break time in' : 'Work time in';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundImage:
                imageProvider ?? const AssetImage('images/logo.png'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  memberName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '$modePrefix - $departmentName',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isCheckIn
                      ? Colors.green.shade50
                      : isCheckOut
                          ? Colors.blue.shade50
                          : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isCheckIn
                      ? 'IN'
                      : isCheckOut
                          ? 'OUT'
                          : '-',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isCheckIn
                        ? Colors.green.shade800
                        : isCheckOut
                            ? Colors.blue.shade800
                            : Colors.grey.shade800,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                timeString,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _composeMemberName(Map<String, dynamic>? memberInfo) {
    final profile = memberInfo?['user_profiles'] as Map<String, dynamic>?;
    if (profile == null) return 'Anggota';
    final displayName = (profile['display_name'] as String?)?.trim();
    if (displayName != null && displayName.isNotEmpty) return displayName;
    final first = profile['first_name'] as String? ?? '';
    final last = profile['last_name'] as String? ?? '';
    final name = '$first $last'.trim();
    return name.isEmpty ? 'Anggota' : name;
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '-';
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String _formatDateTime(DateTime? time) {
    if (time == null) return '-';
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String _formatDate(DateTime? time) {
    if (time == null) return '-';
    final day = time.day.toString().padLeft(2, '0');
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final month = months[time.month - 1];
    final year = time.year;
    return '$day $month $year';
  }

  void _showMenu(BuildContext context) {
    final currentMode = _getWorkTimeMode();
    final isAutoMode = _workTimeMode == null;
    
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(80, 50, 0, 0),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'work_time',
          child: Row(
            children: [
              Icon(
                currentMode == 'work_time' && !isAutoMode ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text(
                'Work time',
                style: TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'break_time',
          child: Row(
            children: [
              Icon(
                currentMode == 'break_time' && !isAutoMode ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text(
                'Break time',
                style: TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'auto',
          child: Row(
            children: [
              Icon(
                isAutoMode ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text(
                'Auto (berdasarkan jadwal)',
                style: TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'work_schedule',
          child: Row(
            children: [
              const Icon(Icons.schedule, color: Color(0xFF9333EA), size: 18),
              const SizedBox(width: 8),
              const Text(
                'Work schedule mode',
                style: TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'sign_data',
          child: Row(
            children: [
              const Icon(Icons.sync, color: Color(0xFF9333EA), size: 18),
              const SizedBox(width: 8),
              const Text(
                'Sign data / Sinkronisasi data',
                style: TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value != null) {
        _handleMenuSelection(value);
      }
    });
  }

  void _handleMenuSelection(String value) {
    switch (value) {
      case 'work_time':
        setState(() {
          _workTimeMode = 'work_time';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mode diubah ke Work time'),
            backgroundColor: Color(0xFF9333EA),
            duration: Duration(seconds: 2),
          ),
        );
        break;
      case 'break_time':
        setState(() {
          _workTimeMode = 'break_time';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mode diubah ke Break time'),
            backgroundColor: Color(0xFF9333EA),
            duration: Duration(seconds: 2),
          ),
        );
        break;
      case 'auto':
        setState(() {
          _workTimeMode = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mode diubah ke Auto (berdasarkan jadwal)'),
            backgroundColor: Color(0xFF9333EA),
            duration: Duration(seconds: 2),
          ),
        );
        break;
      case 'work_schedule':
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Work schedule mode - Coming soon'),
            backgroundColor: Color(0xFF9333EA),
          ),
        );
        break;
      case 'sign_data':
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sign data / Sinkronisasi data - Coming soon'),
            backgroundColor: Color(0xFF9333EA),
          ),
        );
        break;
    }
  }
}

class _AttendanceEntry {
  final int memberId;
  final Map<String, dynamic> memberInfo;
  final AttendanceRecord attendance;
  final String cardNumber;
  final String action;
  final DateTime timestamp;

  _AttendanceEntry({
    required this.memberId,
    required this.memberInfo,
    required this.attendance,
    required this.cardNumber,
    required this.action,
    required this.timestamp,
  });
}