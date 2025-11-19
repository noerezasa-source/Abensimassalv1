// lib/services/face_recognition_service.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

class FaceRecognitionService {
  late final FaceDetector _faceDetector;

  FaceRecognitionService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: true,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );
  }

  // Deteksi wajah dari file gambar
  Future<List<Face>> detectFaces(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    final faces = await _faceDetector.processImage(inputImage);
    return faces;
  }

  // Extract face features untuk template
  Future<Map<String, dynamic>> extractFaceFeatures(String imagePath) async {
    final faces = await detectFaces(imagePath);
    
    if (faces.isEmpty) {
      throw Exception('No face detected in the image');
    }

    if (faces.length > 1) {
      throw Exception('Multiple faces detected. Please use a single face photo');
    }

    return buildTemplateFromFace(faces.first);
  }

  Map<String, dynamic> buildTemplateFromFace(Face face) {
    final boundingBox = face.boundingBox;
    final width = boundingBox.width == 0 ? 1.0 : boundingBox.width;
    final height = boundingBox.height == 0 ? 1.0 : boundingBox.height;

    double normalizeX(num x) =>
        ((x.toDouble() - boundingBox.left) / width).clamp(-0.5, 1.5).toDouble();
    double normalizeY(num y) =>
        ((y.toDouble() - boundingBox.top) / height).clamp(-0.5, 1.5).toDouble();

    final landmarks = <String, dynamic>{};

    void addLandmark(FaceLandmarkType type, String key) {
      final landmark = face.landmarks[type];
      if (landmark == null) return;
      landmarks[key] = {
        'x': normalizeX(landmark.position.x),
        'y': normalizeY(landmark.position.y),
      };
    }

    addLandmark(FaceLandmarkType.leftEye, 'leftEye');
    addLandmark(FaceLandmarkType.rightEye, 'rightEye');
    addLandmark(FaceLandmarkType.noseBase, 'noseBase');
    addLandmark(FaceLandmarkType.leftMouth, 'leftMouth');
    addLandmark(FaceLandmarkType.rightMouth, 'rightMouth');

    final boundingBoxData = {
      'left': boundingBox.left,
      'top': boundingBox.top,
      'width': boundingBox.width,
      'height': boundingBox.height,
    };

    final headAngles = {
      'eulerY': face.headEulerAngleY ?? 0.0,
      'eulerZ': face.headEulerAngleZ ?? 0.0,
    };

    final qualityScores = {
      'smilingProbability': face.smilingProbability ?? 0.0,
      'leftEyeOpenProbability': face.leftEyeOpenProbability ?? 0.0,
      'rightEyeOpenProbability': face.rightEyeOpenProbability ?? 0.0,
    };

    return {
      'version': 2,
      'landmarks': landmarks,
      'boundingBox': boundingBoxData,
      'headAngles': headAngles,
      'qualityScores': qualityScores,
      'trackingId': face.trackingId,
    };
  }

  // Membandingkan dua template wajah
  double compareFaces(
    Map<String, dynamic> template1,
    Map<String, dynamic> template2,
  ) {
    double totalScore = 0.0;
    int comparisonCount = 0;

    // Bandingkan landmarks
    final landmarks1 = _normalizeTemplateLandmarks(template1);
    final landmarks2 = _normalizeTemplateLandmarks(template2);

    for (var key in landmarks1.keys) {
      if (landmarks2.containsKey(key)) {
        final point1 = landmarks1[key] as Map<String, dynamic>;
        final point2 = landmarks2[key] as Map<String, dynamic>;

        final dx = (point1['x'] as num) - (point2['x'] as num);
        final dy = (point1['y'] as num) - (point2['y'] as num);
        final distance = (dx * dx + dy * dy).toDouble();

        // Normalisasi jarak (semakin kecil semakin mirip)
        final similarity = 1.0 / (1.0 + distance / 10000.0);
        totalScore += similarity;
        comparisonCount++;
      }
    }

    // Bandingkan head angles
    final angles1 = template1['headAngles'] as Map<String, dynamic>;
    final angles2 = template2['headAngles'] as Map<String, dynamic>;

    final angleDiffY = ((angles1['eulerY'] as num) - (angles2['eulerY'] as num)).abs();
    final angleDiffZ = ((angles1['eulerZ'] as num) - (angles2['eulerZ'] as num)).abs();
    
    final angleSimilarity = 1.0 - ((angleDiffY + angleDiffZ) / 180.0).clamp(0.0, 1.0);
    totalScore += angleSimilarity;
    comparisonCount++;

    return comparisonCount > 0 ? totalScore / comparisonCount : 0.0;
  }

  // Validasi kualitas foto untuk pendaftaran
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

      // Cek apakah mata terbuka
      final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
      final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;
      
      if (leftEyeOpen < 0.5 || rightEyeOpen < 0.5) {
        throw Exception('Please open your eyes');
      }

      // Cek rotasi kepala tidak terlalu miring
      final headY = (face.headEulerAngleY ?? 0.0).abs();
      final headZ = (face.headEulerAngleZ ?? 0.0).abs();
      
      if (headY > 15.0 || headZ > 15.0) {
        throw Exception('Please face the camera directly');
      }

      // Cek ukuran wajah cukup besar
      final faceSize = face.boundingBox.width * face.boundingBox.height;
      if (faceSize < 10000) {
        throw Exception('Face too small. Please move closer');
      }

      return true;
    } catch (e) {
      rethrow;
    }
  }

  // Compress dan resize image
  Future<Uint8List> compressImage(File imageFile, {int maxWidth = 800}) async {
    final imageBytes = await imageFile.readAsBytes();
    img.Image? image = img.decodeImage(imageBytes);
    
    if (image == null) {
      throw Exception('Failed to decode image');
    }

    // Resize jika terlalu besar
    if (image.width > maxWidth) {
      image = img.copyResize(image, width: maxWidth);
    }

    // Compress ke JPEG dengan quality 85
    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  }

  void dispose() {
    _faceDetector.close();
  }

  Map<String, Map<String, double>> _normalizeTemplateLandmarks(
    Map<String, dynamic> template,
  ) {
    final landmarks =
        Map<String, dynamic>.from(template['landmarks'] ?? const {});

    if (landmarks.isEmpty) return {};

    bool alreadyNormalized = true;
    for (var entry in landmarks.entries) {
      final point = entry.value;
      if (point is! Map) continue;
      final x = point['x'];
      final y = point['y'];
      if (x is num && y is num) {
        if (x < -0.5 || x > 1.5 || y < -0.5 || y > 1.5) {
          alreadyNormalized = false;
          break;
        }
      }
    }

    if (alreadyNormalized) {
      return landmarks.map((key, value) {
        final point = value as Map<String, dynamic>;
        return MapEntry(key, {
          'x': (point['x'] as num?)?.toDouble() ?? 0.0,
          'y': (point['y'] as num?)?.toDouble() ?? 0.0,
        });
      });
    }

    final boundingBox =
        Map<String, dynamic>.from(template['boundingBox'] ?? const {});
    final left = (boundingBox['left'] as num?)?.toDouble() ?? 0.0;
    final top = (boundingBox['top'] as num?)?.toDouble() ?? 0.0;
    final width = (boundingBox['width'] as num?)?.toDouble() ?? 1.0;
    final height = (boundingBox['height'] as num?)?.toDouble() ?? 1.0;

    return landmarks.map((key, value) {
      final point = value as Map<String, dynamic>;
      final rawX = (point['x'] as num?)?.toDouble() ?? 0.0;
      final rawY = (point['y'] as num?)?.toDouble() ?? 0.0;
      final normalizedX = width == 0 ? 0.0 : (rawX - left) / width;
      final normalizedY = height == 0 ? 0.0 : (rawY - top) / height;

      return MapEntry(key, {
        'x': normalizedX.clamp(-0.5, 1.5),
        'y': normalizedY.clamp(-0.5, 1.5),
      });
    });
  }
}