  import 'dart:convert';
  import 'package:flutter/foundation.dart';
  import 'package:supabase_flutter/supabase_flutter.dart';
  import '../models/biometric_data.dart';
  import 'face_recognition_service.dart';

  class BiometricService {
    final SupabaseClient _supabase = Supabase.instance.client;

    // Register face template
    Future<BiometricData> registerFaceTemplate({
      required int organizationMemberId,
      required Map<String, dynamic> faceTemplate,
    }) async {
      try {
        final user = _supabase.auth.currentUser;
        if (user == null) {
          throw Exception('User not authenticated');
        }

        final templateJson = jsonEncode(faceTemplate);

        // Check if template already exists
        final existingTemplate = await _supabase
            .from('biometric_data')
            .select()
            .eq('organization_member_id', organizationMemberId)
            .eq('biometric_type', 'face_recognition')
            .eq('is_active', true)
            .maybeSingle();

        // Deactivate old template if exists
        if (existingTemplate != null) {
          await _supabase
              .from('biometric_data')
              .update({'is_active': false})
              .eq('id', existingTemplate['id']);
        }

        // Insert new template
        final biometricData = {
          'organization_member_id': organizationMemberId,
          'biometric_type': 'face_recognition',
          'template_data': templateJson,
          'enrollment_date': DateTime.now().toIso8601String(),
          'is_active': true,
        };

        final result = await _supabase
            .from('biometric_data')
            .insert(biometricData)
            .select()
            .single();

        return BiometricData.fromJson(result);
      } catch (e) {
        throw Exception('Failed to register face template: $e');
      }
    }

    // Get active face template for single user
    Future<BiometricData?> getActiveFaceTemplate(int organizationMemberId) async {
      try {
        final result = await _supabase
            .from('biometric_data')
            .select()
            .eq('organization_member_id', organizationMemberId)
            .eq('biometric_type', 'face_recognition')
            .eq('is_active', true)
            .maybeSingle();

        if (result == null) return null;

        return BiometricData.fromJson(result);
      } catch (e) {
        debugPrint('Error getting face template: $e');
        return null;
      }
    }

    // ✅ Get all active face templates WITH user info
    Future<List<Map<String, dynamic>>> getAllActiveFaceTemplatesWithUserInfo(
      int organizationId,
    ) async {
      try {
        debugPrint('=== FETCHING FACE TEMPLATES ===');
        debugPrint('Organization ID: $organizationId');

        final results = await _supabase
            .from('biometric_data')
            .select('''
              id,
              organization_member_id,
              template_data,
              organization_members!inner (
                id,
                user_id,
                organization_id,
                employee_id,
                user_profiles!inner (
                  id,
                  first_name,
                  last_name,
                  display_name,
                  profile_photo_url
                )
              )
            ''')
            .eq('biometric_type', 'face_recognition')
            .eq('is_active', true)
            .eq('organization_members.organization_id', organizationId);

        debugPrint('Total templates found: ${results.length}');

        return List<Map<String, dynamic>>.from(results);
      } catch (e) {
        debugPrint('!!! ERROR fetching templates: $e');
        return [];
      }
    }

    // Get all active face templates (backward compatible - without user info)
    Future<List<Map<String, dynamic>>> getAllActiveFaceTemplates(
      int organizationId,
    ) async {
      try {
        final results = await _supabase
            .from('biometric_data')
            .select('''
              id,
              organization_member_id,
              template_data,
              organization_members!inner (
                id,
                user_id,
                organization_id
              )
            ''')
            .eq('biometric_type', 'face_recognition')
            .eq('is_active', true)
            .eq('organization_members.organization_id', organizationId);

        return List<Map<String, dynamic>>.from(results);
      } catch (e) {
        debugPrint('Error getting all face templates: $e');
        return [];
      }
    }

    // Identify user from captured face (returns multiple matches)
    Future<List<Map<String, dynamic>>> identifyUser({
      required Map<String, dynamic> capturedTemplate,
      required int organizationId,
      required double threshold,
    }) async {
      try {
        final allTemplates = await getAllActiveFaceTemplates(organizationId);

        if (allTemplates.isEmpty) {
          throw Exception('No registered faces found in organization');
        }

        final faceService = FaceRecognitionService();
        List<Map<String, dynamic>> matches = [];

        for (var template in allTemplates) {
          final registeredTemplate = jsonDecode(template['template_data']);
          final similarity = faceService.compareFaces(
            capturedTemplate,
            registeredTemplate,
          );

          if (similarity >= threshold) {
            matches.add({
              'organization_member_id': template['organization_member_id'],
              'biometric_id': template['id'],
              'similarity': similarity,
              'organization_id': template['organization_members']['organization_id'],
            });
          }
        }

        // Sort by similarity (highest first)
        matches.sort((a, b) => (b['similarity'] as num).compareTo(a['similarity'] as num));

        return matches;
      } catch (e) {
        throw Exception('Error identifying user: $e');
      }
    }

    // ✅ Identify best match WITH user info (optimized for kiosk mode)
    Future<Map<String, dynamic>?> identifyBestMatchWithUserInfo({
      required Map<String, dynamic> capturedTemplate,
      required int organizationId,
      required double threshold,
    }) async {
      try {
        debugPrint('=== IDENTIFYING BEST MATCH ===');
        debugPrint('Organization ID: $organizationId');
        debugPrint('Threshold: ${(threshold * 100).toStringAsFixed(0)}%');

        final allTemplates = await getAllActiveFaceTemplatesWithUserInfo(organizationId);

        debugPrint('Total templates to compare: ${allTemplates.length}');

        if (allTemplates.isEmpty) {
          debugPrint('No registered faces found in organization');
          return null;
        }

        final faceService = FaceRecognitionService();
        Map<String, dynamic>? bestMatch;
        double highestSimilarity = 0.0;

        for (var template in allTemplates) {
          try {
            final registeredTemplate = jsonDecode(template['template_data']);
            final similarity = faceService.compareFaces(
              capturedTemplate,
              registeredTemplate,
            );

            // Extract nested data
            final orgMember = template['organization_members'];
            final userProfile = orgMember['user_profiles'];
            
            // Build full name
            final firstName = userProfile['first_name'] ?? '';
            final lastName = userProfile['last_name'] ?? '';
            final displayName = userProfile['display_name'] ?? '$firstName $lastName';
            
            debugPrint('Comparing with: $displayName, Similarity: ${(similarity * 100).toStringAsFixed(2)}%');

            if (similarity >= threshold && similarity > highestSimilarity) {
              highestSimilarity = similarity;
              
              bestMatch = {
                'organization_member_id': template['organization_member_id'],
                'biometric_id': template['id'],
                'similarity': similarity,
                'organization_id': orgMember['organization_id'],
                'user_id': orgMember['user_id'],
                'employee_id': orgMember['employee_id'],
                'user_name': displayName.trim(),
                'first_name': firstName,
                'last_name': lastName,
                'profile_photo_url': userProfile['profile_photo_url'],
              };
            }
          } catch (e) {
            debugPrint('Error processing template: $e');
            continue;
          }
        }

        if (bestMatch != null) {
          debugPrint('✅ Best match found: ${bestMatch['user_name']} with ${(bestMatch['similarity'] * 100).toStringAsFixed(2)}% similarity');
        } else {
          debugPrint('❌ No match found above threshold ${(threshold * 100).toStringAsFixed(0)}%');
        }

        return bestMatch;
      } catch (e) {
        debugPrint('!!! ERROR in identifyBestMatchWithUserInfo: $e');
        return null;
      }
    }

    // Get best match (highest similarity) - backward compatible
    Future<Map<String, dynamic>?> identifyBestMatch({
      required Map<String, dynamic> capturedTemplate,
      required int organizationId,
      required double threshold,
    }) async {
      try {
        final matches = await identifyUser(
          capturedTemplate: capturedTemplate,
          organizationId: organizationId,
          threshold: threshold,
        );

        if (matches.isEmpty) return null;

        return matches.first;
      } catch (e) {
        debugPrint('Error getting best match: $e');
        return null;
      }
    }

    // Update last used timestamp
    Future<void> updateLastUsed(int biometricId) async {
      try {
        await _supabase
            .from('biometric_data')
            .update({
              'last_used_at': DateTime.now().toIso8601String(),
            })
            .eq('id', biometricId);
        
        debugPrint('✅ Updated last_used_at for biometric_id: $biometricId');
      } catch (e) {
        debugPrint('Failed to update last used: $e');
      }
    }

    // Deactivate face template
    Future<void> deactivateFaceTemplate(int biometricId) async {
      try {
        await _supabase
            .from('biometric_data')
            .update({'is_active': false})
            .eq('id', biometricId);
        
        debugPrint('✅ Deactivated biometric template: $biometricId');
      } catch (e) {
        throw Exception('Failed to deactivate face template: $e');
      }
    }

    // Check if user has registered face
    Future<bool> hasRegisteredFace(int organizationMemberId) async {
      try {
        final result = await _supabase
            .from('biometric_data')
            .select('id')
            .eq('organization_member_id', organizationMemberId)
            .eq('biometric_type', 'face_recognition')
            .eq('is_active', true)
            .maybeSingle();

        return result != null;
      } catch (e) {
        debugPrint('Error checking face registration: $e');
        return false;
      }
    }

    // ✅ Get organization stats for dashboard
    Future<Map<String, int>> getOrganizationStats(int organizationId) async {
      try {
        debugPrint('=== FETCHING ORGANIZATION STATS ===');
        debugPrint('Organization ID: $organizationId');

        // Count registered faces in this organization
        final registeredData = await _supabase
            .from('biometric_data')
            .select('''
              id,
              organization_members!inner(
                organization_id
              )
            ''')
            .eq('biometric_type', 'face_recognition')
            .eq('is_active', true)
            .eq('organization_members.organization_id', organizationId);
        
        final registeredCount = registeredData.length;

        // Count total active members in organization
        final totalMembersData = await _supabase
            .from('organization_members')
            .select('id')
            .eq('organization_id', organizationId)
            .eq('is_active', true);
        
        final totalMembers = totalMembersData.length;

        debugPrint('Registered faces: $registeredCount');
        debugPrint('Total members: $totalMembers');
        debugPrint('Pending registration: ${totalMembers - registeredCount}');

        return {
          'registered_faces': registeredCount,
          'total_members': totalMembers,
          'pending_registration': totalMembers - registeredCount,
        };
      } catch (e) {
        debugPrint('Error getting organization stats: $e');
        return {
          'registered_faces': 0,
          'total_members': 0,
          'pending_registration': 0,
        };
      }
    }

    // ✅ Get member's biometric info
    Future<Map<String, dynamic>?> getMemberBiometricInfo(int organizationMemberId) async {
      try {
        final result = await _supabase
            .from('biometric_data')
            .select('''
              id,
              biometric_type,
              enrollment_date,
              last_used_at,
              is_active,
              device_id,
              attendance_devices(
                device_name,
                location
              )
            ''')
            .eq('organization_member_id', organizationMemberId)
            .eq('is_active', true);

        if (result.isEmpty) return null;

        return {
          'total_biometric_registrations': result.length,
          'registrations': result,
        };
      } catch (e) {
        debugPrint('Error getting member biometric info: $e');
        return null;
      }
    }

    // ✅ Get biometric usage statistics
    Future<Map<String, dynamic>> getBiometricUsageStats(
      int organizationId, {
      DateTime? startDate,
      DateTime? endDate,
    }) async {
      try {
        final start = startDate ?? DateTime.now().subtract(const Duration(days: 30));
        final end = endDate ?? DateTime.now();

        // Get all active biometric templates in organization
        final templates = await getAllActiveFaceTemplatesWithUserInfo(organizationId);
        
        // Get usage count from attendance_logs
        final usageData = await _supabase
            .from('attendance_logs')
            .select('''
              id,
              organization_member_id,
              event_time,
              method
            ''')
            .gte('event_time', start.toIso8601String())
            .lte('event_time', end.toIso8601String())
            .eq('method', 'face_recognition_kiosk');

        // Count usage per member
        Map<int, int> usagePerMember = {};
        for (var log in usageData) {
          final memberId = log['organization_member_id'] as int;
          usagePerMember[memberId] = (usagePerMember[memberId] ?? 0) + 1;
        }

        return {
          'total_templates': templates.length,
          'total_usage': usageData.length,
          'date_range': {
            'start': start.toIso8601String(),
            'end': end.toIso8601String(),
          },
          'usage_per_member': usagePerMember,
          'active_users': usagePerMember.length,
        };
      } catch (e) {
        debugPrint('Error getting biometric usage stats: $e');
        return {
          'total_templates': 0,
          'total_usage': 0,
          'active_users': 0,
        };
      }
    }

    // ✅ Batch deactivate templates (for maintenance)
    Future<int> batchDeactivateTemplates(List<int> biometricIds) async {
      try {
        await _supabase
            .from('biometric_data')
            .update({'is_active': false})
            .inFilter('id', biometricIds);
        
        debugPrint('✅ Batch deactivated ${biometricIds.length} templates');
        return biometricIds.length;
      } catch (e) {
        debugPrint('Error batch deactivating templates: $e');
        return 0;
      }
    }

    // ✅ Get members without biometric registration
    Future<List<Map<String, dynamic>>> getMembersWithoutBiometric(
      int organizationId,
    ) async {
      try {
        // Get all members
        final allMembers = await _supabase
            .from('organization_members')
            .select('''
              id,
              employee_id,
              user_id,
              hire_date,
              employment_status,
              user_profiles!inner(
                first_name,
                last_name,
                display_name,
                profile_photo_url
              )
            ''')
            .eq('organization_id', organizationId)
            .eq('is_active', true);

        // Get registered members
        final registeredMembers = await _supabase
            .from('biometric_data')
            .select('organization_member_id')
            .eq('biometric_type', 'face_recognition')
            .eq('is_active', true);

        final registeredIds = registeredMembers
            .map((e) => e['organization_member_id'] as int)
            .toSet();

        // Filter unregistered members
        final unregisteredMembers = allMembers.where((member) {
          return !registeredIds.contains(member['id']);
        }).toList();

        debugPrint('Members without biometric: ${unregisteredMembers.length}');
        
        return unregisteredMembers;
      } catch (e) {
        debugPrint('Error getting members without biometric: $e');
        return [];
      }
    }

    // Clean up old/inactive templates
    Future<int> cleanupInactiveTemplates(int organizationId, {int daysOld = 180}) async {
      try {
        final cutoffDate = DateTime.now().subtract(Duration(days: daysOld));
        
        final oldTemplates = await _supabase
            .from('biometric_data')
            .select('''
              id,
              organization_members!inner(
                organization_id
              )
            ''')
            .eq('is_active', false)
            .eq('organization_members.organization_id', organizationId)
            .lt('updated_at', cutoffDate.toIso8601String());

        if (oldTemplates.isEmpty) {
          debugPrint('No old templates to cleanup');
          return 0;
        }

        final idsToDelete = oldTemplates.map((t) => t['id'] as int).toList();
        
        await _supabase
            .from('biometric_data')
            .delete()
            .inFilter('id', idsToDelete);

        debugPrint('✅ Cleaned up ${idsToDelete.length} old templates');
        return idsToDelete.length;
      } catch (e) {
        debugPrint('Error cleaning up templates: $e');
        return 0;
      }
    }

    // Dispose resources
    void dispose() {
      // Cleanup if needed
      debugPrint('BiometricService disposed');
    }
  }