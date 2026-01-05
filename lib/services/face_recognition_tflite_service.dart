// lib/services/face_recognition_tflite_service.dart
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img; // Keep for validatePhotoQuality
import 'isolate_inference_service.dart';

class FaceRecognitionTFLiteService {
  late final FaceDetector _faceDetector;
  final IsolateInferenceService _inferenceService = IsolateInferenceService();
  bool _isInitialized = false;

  // Model config
  int inputSize = 112; 
  int embeddingSize = 192; 
  
  // ✅ IMPROVED: Relaxed quality thresholds for distance/motion
  static const double minFaceQualityScore = 0.25; // Drastically lowered from 0.5 to fix gender bias
  static const double minEyeOpenProbability = 0.1; // Lowered to 0.1 to allow makeup/lashes
  static const double maxHeadRotation = 30.0; // Increased from 15.0
  
  FaceRecognitionTFLiteService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true, // Needed for alignment
        enableClassification: true, // Needed for eye open prob
        enableTracking: true, // ✅ ENABLED: For persistent ID tracking
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.1, // ✅ LOWERED: Detect smaller faces (further away)
      ),
    );
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('=== Initializing Face Recognition Service ===');
      await _inferenceService.initialize();
      // We assume default sizes for MobileFaceNet if we can't get them from isolate immediately
      // or we could add a method to get model info from isolate.
      // For now, hardcoding as per previous generic implementation or relying on defaults.
      debugPrint('✅ Face Recognition Service initialized');
      _isInitialized = true;
    } catch (e) {
      debugPrint('!!! Failed to initialize Face Recognition Service: $e');
      rethrow;
    }
  }

  Future<List<Face>> detectFaces(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    final faces = await _faceDetector.processImage(inputImage);
    return faces;
  }

  // ✅ NEW: Calculate face quality score
  double calculateFaceQuality(Face face) {
    double qualityScore = 1.0;
    
    // Eye openness (40% weight)
    final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;
    final eyeScore = (leftEyeOpen + rightEyeOpen) / 2.0;
    qualityScore *= (0.6 + eyeScore * 0.4);
    
    // Head rotation (30% weight)
    final headY = (face.headEulerAngleY ?? 0.0).abs();
    final headZ = (face.headEulerAngleZ ?? 0.0).abs();
    final rotationPenalty = (headY + headZ) / 100.0; // normalize
    qualityScore *= (1.0 - rotationPenalty.clamp(0.0, 0.3));
    
    // Face size (30% weight) - larger faces are better
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    final sizeScore = (faceArea / 100000.0).clamp(0.0, 1.0);
    qualityScore *= (0.7 + sizeScore * 0.3);
    
    return qualityScore.clamp(0.0, 1.0);
  }

  // ✅ IMPROVED: Filter faces by quality before processing
  bool isValidFaceForRecognition(Face face, {bool allowSidePose = false}) {
    // Check eye openness
    final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;
    if (leftEyeOpen < minEyeOpenProbability || rightEyeOpen < minEyeOpenProbability) {
      debugPrint('❌ Face rejected: Eyes not open enough');
      return false;
    }
    
    // Check head rotation
    if (!allowSidePose) {
      final headY = (face.headEulerAngleY ?? 0.0).abs();
      final headZ = (face.headEulerAngleZ ?? 0.0).abs();
      if (headY > maxHeadRotation || headZ > maxHeadRotation) {
        debugPrint('❌ Face rejected: Head rotation too large');
        return false;
      }
    } else {
      final headZ = (face.headEulerAngleZ ?? 0.0).abs();
      final headY = (face.headEulerAngleY ?? 0.0).abs();
      if (headZ > maxHeadRotation) {
        debugPrint('❌ Face rejected: Head tilt too large (Z: ${headZ.toStringAsFixed(1)}°)');
        return false;
      }
      if (headY > 50.0) {
        debugPrint('❌ Face rejected: Head rotation too extreme (Y: ${headY.toStringAsFixed(1)}°)');
        return false;
      }
    }
    
    // Check face size
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    if (faceArea < 8000) { 
      debugPrint('❌ Face rejected: Face too small');
      return false;
    }
    
    final qualityScore = calculateFaceQuality(face);
    final minQuality = allowSidePose ? (minFaceQualityScore * 0.85) : minFaceQualityScore;
    if (qualityScore < minQuality) {
      debugPrint('❌ Face rejected: Quality score too low (${qualityScore.toStringAsFixed(2)})');
      return false;
    }
    
    return true;
  }

  Future<Map<String, dynamic>> extractFaceFeatures(
    String imagePath, {
    bool allowSidePose = false,
  }) async {
    final faces = await detectFaces(imagePath);
    
    if (faces.isEmpty) {
      throw Exception('No face detected in the image');
    }

    if (faces.length > 1) {
      throw Exception('Multiple faces detected. Please use a single face photo');
    }

    final face = faces.first;
    
    if (!isValidFaceForRecognition(face, allowSidePose: allowSidePose)) {
      throw Exception('Face quality insufficient. Please ensure good lighting${allowSidePose ? '' : ' and look straight at camera'}');
    }

    return buildTemplateFromFace(face, imagePath, allowSidePose: allowSidePose);
  }

  Future<Map<String, dynamic>> buildTemplateFromFace(
    Face face,
    String imagePath, {
    bool allowSidePose = false,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    // Prepare face data for isolate
    final landmarks = <String, dynamic>{};
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    if (leftEye != null) {
      landmarks['leftEye'] = {'x': leftEye.position.x, 'y': leftEye.position.y};
    }
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    if (rightEye != null) {
      landmarks['rightEye'] = {'x': rightEye.position.x, 'y': rightEye.position.y};
    }

    final faceData = {
      'boundingBox': {
        'left': face.boundingBox.left,
        'top': face.boundingBox.top,
        'width': face.boundingBox.width,
        'height': face.boundingBox.height,
      },
      'landmarks': landmarks,
    };

    // Run inference in background isolate
    final response = await _inferenceService.processFace(
      imagePath: imagePath,
      faceData: faceData,
      allowSidePose: allowSidePose,
    );

    if (response.error != null) {
      throw Exception(response.error);
    }
    
    if (response.embedding == null) {
      throw Exception('Failed to generate embedding');
    }

    return _buildTemplate(face, response.embedding!);
  }

  Map<String, dynamic> _buildTemplate(Face face, List<double> embedding) {
    final qualityScore = calculateFaceQuality(face);
    
    return {
      'version': 3,
      'embedding': embedding,
      'embeddingSize': embedding.length,
      'qualityScore': qualityScore,
      'boundingBox': {
        'left': face.boundingBox.left,
        'top': face.boundingBox.top,
        'width': face.boundingBox.width,
        'height': face.boundingBox.height,
      },
      'qualityScores': {
        'leftEyeOpen': face.leftEyeOpenProbability ?? 0.0,
        'rightEyeOpen': face.rightEyeOpenProbability ?? 0.0,
        'smiling': face.smilingProbability ?? 0.0,
      },
      'headAngles': {
        'eulerY': face.headEulerAngleY ?? 0.0,
        'eulerZ': face.headEulerAngleZ ?? 0.0,
      },
    };
  }

  // ✅ NEW: Build multi-template with 3 poses (front, left, right)
  Map<String, dynamic> buildMultiTemplate(List<Map<String, dynamic>> templates) {
    if (templates.length != 3) {
      throw Exception('Multi-template requires exactly 3 templates (front, left, right)');
    }

    return {
      'version': 4, 
      'templates': templates,
      'templateCount': templates.length,
      'embeddingSize': templates.first['embeddingSize'] ?? 192,
    };
  }

  double compareFaces(
    Map<String, dynamic> template1,
    Map<String, dynamic> template2,
  ) {
    final embedding1 = List<double>.from(template1['embedding'] ?? []);
    final embedding2 = List<double>.from(template2['embedding'] ?? []);

    if (embedding1.isEmpty || embedding2.isEmpty) {
      return 0.0;
    }

    if (embedding1.length != embedding2.length) {
      debugPrint('!!! Embedding size mismatch: ${embedding1.length} vs ${embedding2.length}');
      return 0.0;
    }

    double dotProduct = 0.0;
    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
    }

    final cosineSimilarity = dotProduct.clamp(-1.0, 1.0);
    final similarity = (cosineSimilarity + 1.0) / 2.0;
    
    return similarity;
  }

  Future<bool> validatePhotoQuality(String imagePath) async {
    try {
      final faces = await detectFaces(imagePath);
      
      if (faces.isEmpty) {
        throw Exception('No face detected');
      }

      if (faces.length > 1) {
        throw Exception('Multiple faces detected');
      }

      final face = faces.first;

      if (!isValidFaceForRecognition(face, allowSidePose: false)) {
        final qualityScore = calculateFaceQuality(face);
        throw Exception('Face quality insufficient (score: ${qualityScore.toStringAsFixed(2)})');
      }

      final imageFile = File(imagePath);
      final imageBytes = await imageFile.readAsBytes();
      final image = img.decodeImage(imageBytes);
      
      if (image != null) {
        final imageArea = image.width * image.height;
        final faceArea = face.boundingBox.width * face.boundingBox.height;
        final faceRatio = faceArea / imageArea;
        
        if (faceRatio < 0.05) { // ✅ LOWERED: Allow 5% face area (was 15%)
          throw Exception('Face too small. Please move closer');
        }

        if (faceRatio > 0.80) {
          throw Exception('Face too close. Please move back');
        }
      }

      return true;
    } catch (e) {
      rethrow;
    }
  }

  Map<String, dynamic> getModelInfo() {
    if (!_isInitialized) {
      return {'status': 'not_initialized'};
    }
    // Isolate service doesn't easily expose this, but we can assume hardcoded values for now
    // as it's just for debugging/info
    return {
      'status': 'initialized',
      'inputSize': inputSize,
      'embeddingSize': embeddingSize,
    };
  }

  void dispose() {
    _faceDetector.close();
    _inferenceService.dispose();
    _isInitialized = false;
    debugPrint('FaceRecognitionTFLiteService disposed');
  }
}