import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/attendance_service.dart';
import '../services/role_service.dart';
import '../services/member_performance_service.dart';
import '../helpers/timezone_helper.dart';
import '../widgets/petugas_bottom_nav.dart';
import 'petugas_dashboard.dart';
import 'petugas_records_page.dart';
import 'petugas_profile_page.dart';

class PetugasMembersPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const PetugasMembersPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
  });

  @override
  State<PetugasMembersPage> createState() => _PetugasMembersPageState();
}

class _PetugasMembersPageState extends State<PetugasMembersPage>
    with SingleTickerProviderStateMixin {
  static const Color primaryColor = Color(0xFF6B46C1);
  static const Color successColor = Color(0xFF10B981);
  static const Color warningColor = Color(0xFFF59E0B);
  static const Color errorColor = Color(0xFFEF4444);
  static const Color backgroundColor = Color(0xFF1F2937);

  final SupabaseClient _supabase = Supabase.instance.client;
  final AttendanceService _attendanceService = AttendanceService();
  final RoleService _roleService = RoleService();
  final MemberPerformanceService _performanceService = MemberPerformanceService();

  bool _isLoading = true;
  bool _isLoadingPerformance = false;
  bool _isLoadingActivities = false;
  String? _errorMessage;
  int _currentNavIndex = 1;
  String _organizationTimezone = 'Asia/Jakarta';

  List<Map<String, dynamic>> _organizationMembers = [];
  Map<String, dynamic>? _organization;
  Map<String, dynamic> _memberPerformanceStats = {};
  List<Map<String, dynamic>> _topPerformers = [];
  List<Map<String, dynamic>> _lowPerformers = [];
  List<Map<String, dynamic>> _recentActivities = [];
  String _searchQuery = '';
  String _selectedDepartment = 'All';
  List<String> _departments = ['All'];

  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadDataOptimized();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadDataOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== STARTING FAST DATA LOADING ===');
    
    // Load everything in parallel for fastest response
    await Future.wait([
      _loadOrganizationData(),
      _loadOrganizationMembersOptimized(),
      _loadPerformanceStatsOptimized(),
    ]);
    
    // Load activities separately to not block main content
    _loadRecentActivitiesOptimized();
  }

  Future<void> _loadOrganizationMembersOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING ORGANIZATION MEMBERS (OPTIMIZED) ===');
    debugPrint('Organization ID: $organizationId');

    try {
      final members = await _performanceService.getOrganizationMembers(organizationId);
      
      debugPrint('Received ${members.length} members from service');
      
      if (mounted) {
        setState(() {
          _organizationMembers = members;
          
          // Extract departments for filtering
          final deptSet = <String>{'All'};
          for (final member in members) {
            final dept = member['departments'] as Map<String, dynamic>?;
            if (dept != null && dept['name'] != null) {
              deptSet.add(dept['name'] as String);
            }
          }
          _departments = deptSet.toList();
          
          _isLoading = false;
        });
        
        debugPrint('State updated - Members: ${_organizationMembers.length}');
      }
    } catch (e) {
      debugPrint('!!! ERROR loading organization members: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load members: $e';
        });
      }
    }
  }

  Future<void> _loadPerformanceStatsOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING PERFORMANCE STATS (OPTIMIZED) ===');

    setState(() => _isLoadingPerformance = true);

    try {
      // Get organization performance summary
      final summary = await _performanceService.getOrganizationPerformanceSummary(organizationId);
      
      // Get top performers only (limit to 10 for faster loading)
      final performers = await _performanceService.getMembersPerformanceData(
        organizationId,
        limit: 10,
      );

      if (mounted) {
        setState(() {
          _memberPerformanceStats = summary;
          _topPerformers = performers.take(5).toList();
          _lowPerformers = performers.reversed.take(5).toList();
          _isLoadingPerformance = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading performance stats: $e');
      if (mounted) {
        setState(() {
          _isLoadingPerformance = false;
        });
      }
    }
  }

  Future<void> _loadRecentActivitiesOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING RECENT ACTIVITIES (OPTIMIZED) ===');

    setState(() => _isLoadingActivities = true);

    try {
      final activities = await _performanceService.getRecentMemberActivities(
        organizationId,
        limit: 5, // Limit to 5 for faster loading
      );
      
      debugPrint('Recent activities loaded: ${activities.length}');
      
      if (mounted) {
        setState(() {
          _recentActivities = activities;
          _isLoadingActivities = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading recent activities: $e');
      if (mounted) {
        setState(() {
          _isLoadingActivities = false;
        });
      }
    }
  }

  Future<void> _loadOrganizationData() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final org = await _supabase
          .from('organizations')
          .select('id, name, logo_url, timezone')
          .eq('id', organizationId)
          .single();

      if (mounted && org != null) {
        setState(() {
          _organization = org;
          if (org['timezone'] != null) {
            _organizationTimezone = org['timezone'];
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading organization data: $e');
    }
  }

  Future<void> _loadOrganizationMembers() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING ORGANIZATION MEMBERS ===');
    debugPrint('Organization ID: $organizationId');
    debugPrint('Member data: ${widget.memberData}');

    setState(() => _isLoading = true);

    try {
      final members = await _performanceService.getOrganizationMembers(organizationId);
      
      debugPrint('Received ${members.length} members from service');
      
      if (mounted) {
        setState(() {
          _organizationMembers = members;
          
          // Extract departments for filtering
          final deptSet = <String>{'All'};
          for (final member in members) {
            final dept = member['departments'] as Map<String, dynamic>?;
            if (dept != null && dept['name'] != null) {
              deptSet.add(dept['name'] as String);
            }
          }
          _departments = deptSet.toList();
          
          _isLoading = false;
        });
        
        debugPrint('State updated - Members: ${_organizationMembers.length}');
        debugPrint('Departments: $_departments');
      }
    } catch (e) {
      debugPrint('!!! ERROR loading organization members: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load members: $e';
        });
      }
    }
  }

  Future<void> _loadPerformanceStats() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING PERFORMANCE STATS ===');
    debugPrint('Organization ID: $organizationId');

    setState(() => _isLoadingPerformance = true);

    try {
      // Get organization performance summary
      final summary = await _performanceService.getOrganizationPerformanceSummary(organizationId);
      debugPrint('Performance summary received: $summary');
      
      // Get top and low performers
      final performers = await _performanceService.getMembersPerformanceData(
        organizationId,
        limit: 50,
      );
      debugPrint('Performers data count: ${performers.length}');

      if (mounted) {
        setState(() {
          _memberPerformanceStats = summary;
          _topPerformers = performers.take(5).toList();
          _lowPerformers = performers.reversed.take(5).toList();
          _isLoadingPerformance = false;
        });
        
        debugPrint('Performance stats updated successfully');
        debugPrint('Top performers: ${_topPerformers.length}');
        debugPrint('Low performers: ${_lowPerformers.length}');
      }
    } catch (e) {
      debugPrint('!!! ERROR loading performance stats: $e');
      if (mounted) {
        setState(() {
          _isLoadingPerformance = false;
        });
      }
    }
  }

  Future<void> _loadRecentActivities() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING RECENT ACTIVITIES ===');
    debugPrint('Organization ID: $organizationId');

    try {
      final activities = await _performanceService.getRecentMemberActivities(
        organizationId,
        limit: 10,
      );
      
      debugPrint('Recent activities loaded: ${activities.length}');
      
      if (mounted) {
        setState(() {
          _recentActivities = activities;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading recent activities: $e');
    }
  }

  Future<void> _testDatabaseConnection() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final testResult = await _performanceService.testDatabaseConnection(organizationId);
      debugPrint('=== DATABASE TEST RESULT ===');
      debugPrint('Test result: $testResult');
      
      if (testResult['error'] != null) {
        debugPrint('Database connection error: ${testResult['error']}');
      } else {
        debugPrint('Database connection successful!');
        debugPrint('Organization exists: ${testResult['organization_exists']}');
        debugPrint('Active members: ${testResult['active_members_count']}');
        debugPrint('Attendance records: ${testResult['attendance_records_count']}');
      }
    } catch (e) {
      debugPrint('!!! ERROR in database test: $e');
    }
  }

  List<Map<String, dynamic>> get _filteredMembers {
    return _organizationMembers.where((member) {
      // Filter by search query
      if (_searchQuery.isNotEmpty) {
        final profile = member['user_profiles'] as Map<String, dynamic>?;
        final displayName = profile?['display_name'] as String? ?? '';
        final firstName = profile?['first_name'] as String? ?? '';
        final lastName = profile?['last_name'] as String? ?? '';
        final employeeId = member['employee_id'] as String? ?? '';
        final query = _searchQuery.toLowerCase();
        
        final fullName = '$displayName $firstName $lastName $employeeId'.toLowerCase();
        if (!fullName.contains(query)) return false;
      }

      // Filter by department
      if (_selectedDepartment != 'All') {
        final dept = member['departments'] as Map<String, dynamic>?;
        final deptName = dept?['name'] as String? ?? '';
        if (deptName != _selectedDepartment) return false;
      }

      return true;
    }).toList();
  }

  void _handleNavigation(int index) {
    if (index == _currentNavIndex) return;

    setState(() {
      _currentNavIndex = index;
    });

    switch (index) {
      case 0:
        Navigator.popUntil(context, (route) => route.isFirst);
        break;
      case 1:
        // Members - stay on current page
        break;
      case 2:
        Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (context) => PetugasRecordsPage(
              organizationMemberId: widget.organizationMemberId,
              memberData: widget.memberData,
              userProfile: widget.userProfile,
            ),
          ),
        ).then((_) {
          setState(() {
            _currentNavIndex = 1;
          });
        });
        break;
      case 3:
        Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (context) => PetugasProfilePage(
              organizationMemberId: widget.organizationMemberId,
              memberData: widget.memberData,
              userProfile: widget.userProfile,
            ),
          ),
        ).then((_) {
          setState(() {
            _currentNavIndex = 1;
          });
        });
        break;
    }
  }

  String _getMemberName(Map<String, dynamic> member) {
    final profile = member['user_profiles'] as Map<String, dynamic>?;
    if (profile == null) return 'Unknown User';

    final displayName = profile['display_name'] as String?;
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }

    final firstName = profile['first_name'] as String? ?? '';
    final lastName = profile['last_name'] as String? ?? '';
    final fullName = '$firstName $lastName'.trim();
    return fullName.isEmpty ? 'Unknown User' : fullName;
  }

  String? _getMemberPhotoUrl(Map<String, dynamic> member) {
    final profile = member['user_profiles'] as Map<String, dynamic>?;
    final photoPath = profile?['profile_photo_url'] as String?;

    if (photoPath == null || photoPath.trim().isEmpty) return null;

    if (photoPath.startsWith('http://') || photoPath.startsWith('https://')) {
      return photoPath;
    }

    return _supabase.storage
        .from('profile-photos')
        .getPublicUrl('mass-profile/$photoPath');
  }

  String _formatPercentage(double value) {
    return '${(value * 100).toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        body: const Center(child: CircularProgressIndicator(color: primaryColor)),
        bottomNavigationBar: PetugasBottomNav(
          currentIndex: _currentNavIndex,
          onNavigationTap: _handleNavigation,
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: NestedScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverToBoxAdapter(child: _buildHeader()),
            SliverPersistentHeader(
              pinned: true,
              delegate: _SliverTabBarDelegate(
                TabBar(
                  controller: _tabController,
                  labelColor: primaryColor,
                  unselectedLabelColor: Colors.grey,
                  indicatorColor: primaryColor,
                  indicatorWeight: 3,
                  labelStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  tabs: const [
                    Tab(text: 'Overview'),
                    Tab(text: 'Members'),
                    Tab(text: 'Performance'),
                  ],
                ),
              ),
            ),
          ];
        },
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildOverviewTab(),
            _buildMembersTab(),
            _buildPerformanceTab(),
          ],
        ),
      ),
      bottomNavigationBar: PetugasBottomNav(
        currentIndex: _currentNavIndex,
        onNavigationTap: _handleNavigation,
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [backgroundColor, Color(0xFF374151)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: _organization?['logo_url'] != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          _organization!['logo_url']!,
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return _buildDefaultLogo();
                          },
                        ),
                      )
                    : _buildDefaultLogo(),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Member Management',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _organization?['name'] ?? 'Unknown Organization',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultLogo() {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: primaryColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.business, color: Colors.white, size: 28),
    );
  }

  Widget _buildOverviewTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatsCards(),
          const SizedBox(height: 24),
          _buildRecentActivities(),
          const SizedBox(height: 20), // Add bottom padding
        ],
      ),
    );
  }

 Widget _buildStatsCards() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Statistics Overview',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _buildStatCard(
              'Total Members',
              '${_memberPerformanceStats['total_members'] ?? 0}',
              Icons.people,
              Colors.blue,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard(
              'Active Members',
              '${_memberPerformanceStats['active_members'] ?? 0}',
              Icons.person,
              Colors.green,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _buildStatCard(
              'Avg Attendance',
              _formatPercentage(_memberPerformanceStats['avg_attendance_rate'] ?? 0.0),
              Icons.calendar_today,
              Colors.orange,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard(
              'Avg Punctuality',
              _formatPercentage(_memberPerformanceStats['avg_punctuality_rate'] ?? 0.0),
              Icons.schedule,
              Colors.purple,
            ),
          ),
        ],
      ),
    ],
  );
}

 Widget _buildStatCard(String title, String value, IconData icon, Color color) {
  return Container(
    height: 110, // Set fixed height
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.06),
          blurRadius: 10,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
                height: 1.0,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ],
    ),
  );
}

  Widget _buildQuickInsights() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quick Insights',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            children: [
              _buildInsightItem(
                'Best performing department',
                'Engineering Team',
                Icons.trending_up,
                Colors.green,
              ),
              const Divider(),
              _buildInsightItem(
                'Members with perfect attendance',
                '12 members this month',
                Icons.star,
                Colors.orange,
              ),
              const Divider(),
              _buildInsightItem(
                'Needs attention',
                '3 members with low punctuality',
                Icons.warning,
                Colors.red,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInsightItem(String title, String value, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentActivities() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recent Today Activity',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          constraints: const BoxConstraints(
            maxHeight: 400, // Limit height to prevent overflow
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: _isLoadingActivities
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Column(
                      children: [
                        CircularProgressIndicator(color: primaryColor),
                        SizedBox(height: 12),
                        Text(
                          'Loading activities...',
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : _recentActivities.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.history,
                              size: 48,
                              color: Colors.grey,
                            ),
                            SizedBox(height: 12),
                            Text(
                              'No activities today',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Today\'s activities will appear here',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _recentActivities.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final activity = _recentActivities[index];
                        final memberName = activity['member_name'] as String? ?? 'Unknown';
                        final eventType = activity['event_type'] as String? ?? 'Unknown';
                        final timeAgo = activity['time_ago'] as String? ?? 'Unknown time';
                        final method = activity['method'] as String? ?? '';
                        final memberInfo = activity['member_info'] as Map<String, dynamic>? ?? {};
                        
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.grey.shade200,
                            backgroundImage: _getMemberPhotoUrl(memberInfo) != null
                                ? NetworkImage(_getMemberPhotoUrl(memberInfo)!)
                                : null,
                            child: _getMemberPhotoUrl(memberInfo) == null
                                ? Icon(Icons.person, color: Colors.grey.shade600)
                                : null,
                          ),
                          title: Text(
                            memberName,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            _getActivityDescription(eventType, method),
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 13,
                            ),
                          ),
                          trailing: Text(
                            timeAgo,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  String _getActivityDescription(String eventType, String method) {
    switch (eventType.toLowerCase()) {
      case 'check_in':
        return 'Checked in ${method.isNotEmpty ? 'via $method' : ''}';
      case 'check_out':
        return 'Checked out ${method.isNotEmpty ? 'via $method' : ''}';
      case 'break_start':
        return 'Started break';
      case 'break_end':
        return 'Ended break';
      case 'overtime_start':
        return 'Started overtime';
      case 'overtime_end':
        return 'Ended overtime';
      default:
        return '$eventType${method.isNotEmpty ? ' via $method' : ''}';
    }
  }

  Widget _buildMembersTab() {
    return Column(
      children: [
        _buildFiltersAndSearch(),
        Expanded(
          child: _buildMembersList(),
        ),
      ],
    );
  }

  Widget _buildFiltersAndSearch() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          TextField(
            decoration: InputDecoration(
              hintText: 'Search members...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _searchQuery = '';
                        });
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _selectedDepartment,
            decoration: const InputDecoration(
              labelText: 'Department',
              prefixIcon: Icon(Icons.business),
            ),
            items: _departments.map((dept) {
              return DropdownMenuItem(
                value: dept,
                child: Text(dept),
              );
            }).toList(),
            onChanged: (value) {
              setState(() {
                _selectedDepartment = value!;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMembersList() {
    final filteredMembers = _filteredMembers;
    
    if (filteredMembers.isEmpty) {
      return const Center(
        child: Text('No members found'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: filteredMembers.length,
      itemBuilder: (context, index) {
        final member = filteredMembers[index];
        return _buildMemberCard(member);
      },
    );
  }

  Widget _buildMemberCard(Map<String, dynamic> member) {
    final profile = member['user_profiles'] as Map<String, dynamic>?;
    final department = member['departments'] as Map<String, dynamic>?;
    final position = member['positions'] as Map<String, dynamic>?;
    final performance = member['performance_stats'] as Map<String, dynamic>?;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.grey.shade200,
            backgroundImage: _getMemberPhotoUrl(member) != null
                ? CachedNetworkImageProvider(_getMemberPhotoUrl(member)!)
                : null,
            child: _getMemberPhotoUrl(member) == null
                ? Icon(Icons.person, color: Colors.grey.shade600)
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _getMemberName(member),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                if (department != null) ...[
                  Text(
                    department['name'] ?? 'No Department',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
                if (position != null) ...[
                  Text(
                    position['title'] ?? 'No Position',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
                if (performance != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _buildPerformanceBadge(
                        'Attendance',
                        _formatPercentage(performance['attendance_rate']),
                        performance['attendance_rate'] > 0.9
                            ? Colors.green
                            : performance['attendance_rate'] > 0.8
                                ? Colors.orange
                                : Colors.red,
                      ),
                      const SizedBox(width: 8),
                      _buildPerformanceBadge(
                        'Punctuality',
                        _formatPercentage(performance['punctuality_rate']),
                        performance['punctuality_rate'] > 0.9
                            ? Colors.green
                            : performance['punctuality_rate'] > 0.8
                                ? Colors.orange
                                : Colors.red,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Icon(
            Icons.arrow_forward_ios,
            size: 16,
            color: Colors.grey.shade400,
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 8,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTopPerformers(),
            const SizedBox(height: 20),
            _buildLowPerformers(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopPerformers() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.trending_up, color: Colors.green),
            const SizedBox(width: 8),
            const Text(
              'Top Performers',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'This Month',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.green,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _topPerformers.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final member = _topPerformers[index];
              final performance = member['performance_stats'] as Map<String, dynamic>;
              return _buildPerformerListItem(member, performance, index + 1, true);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLowPerformers() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.trending_down, color: Colors.red),
            const SizedBox(width: 8),
            const Text(
              'Needs Attention',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'This Month',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _lowPerformers.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final member = _lowPerformers[index];
              final performance = member['performance_stats'] as Map<String, dynamic>;
              return _buildPerformerListItem(member, performance, index + 1, false);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPerformerListItem(
    Map<String, dynamic> member,
    Map<String, dynamic> performance,
    int rank,
    bool isTopPerformer,
  ) {
    final color = isTopPerformer ? Colors.green : Colors.red;
    
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.1),
        child: Text(
          rank.toString(),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
      title: Text(_getMemberName(member)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Productivity Score: ${_formatPercentage(performance['productivity_score'])}',
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _buildMiniBadge(
                'Attendance',
                _formatPercentage(performance['attendance_rate']),
                performance['attendance_rate'] > 0.8 ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              _buildMiniBadge(
                'Punctuality',
                _formatPercentage(performance['punctuality_rate']),
                performance['punctuality_rate'] > 0.8 ? Colors.green : Colors.orange,
              ),
            ],
          ),
        ],
      ),
      trailing: Icon(
        isTopPerformer ? Icons.emoji_events : Icons.warning,
        color: color,
      ),
    );
  }

  Widget _buildMiniBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;

  _SliverTabBarDelegate(this.tabBar);

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: Colors.white,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return false;
  }
}
