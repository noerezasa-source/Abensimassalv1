// lib/services/face_recognition_tflite_service.dart
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceRecognitionTFLiteService {
  late final FaceDetector _faceDetector;
  Interpreter? _interpreter;
  bool _isInitialized = false;

  // Model config
  static const int inputSize = 112;
  static const int embeddingSize = 192;
  
  // ✅ IMPROVED: Stricter quality thresholds
  static const double minFaceQualityScore = 0.6;
  static const double minEyeOpenProbability = 0.4;
  static const double maxHeadRotation = 20.0;
  
  FaceRecognitionTFLiteService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: false,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.12, // ✅ Slightly increased for better quality
      ),
    );
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('=== Initializing TFLite Model ===');
      
      _interpreter = await Interpreter.fromAsset(
        'assets/models/mobile_face_net.tflite',
        options: InterpreterOptions()
          ..threads = 4
          ..useNnApiForAndroid = true,
      );

      final inputShape = _interpreter!.getInputTensor(0).shape;
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      
      debugPrint('Input shape: $inputShape');
      debugPrint('Output shape: $outputShape');
      debugPrint('✅ TFLite model loaded successfully');
      
      _isInitialized = true;
    } catch (e) {
      debugPrint('!!! Failed to load TFLite model: $e');
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
  bool isValidFaceForRecognition(Face face) {
    // Check eye openness
    final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;
    if (leftEyeOpen < minEyeOpenProbability || rightEyeOpen < minEyeOpenProbability) {
      debugPrint('❌ Face rejected: Eyes not open enough');
      return false;
    }
    
    // Check head rotation
    final headY = (face.headEulerAngleY ?? 0.0).abs();
    final headZ = (face.headEulerAngleZ ?? 0.0).abs();
    if (headY > maxHeadRotation || headZ > maxHeadRotation) {
      debugPrint('❌ Face rejected: Head rotation too large');
      return false;
    }
    
    // Check face size
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    if (faceArea < 8000) { // Minimum face area
      debugPrint('❌ Face rejected: Face too small');
      return false;
    }
    
    // Calculate overall quality
    final qualityScore = calculateFaceQuality(face);
    if (qualityScore < minFaceQualityScore) {
      debugPrint('❌ Face rejected: Quality score too low (${qualityScore.toStringAsFixed(2)})');
      return false;
    }
    
    debugPrint('✅ Face quality: ${qualityScore.toStringAsFixed(2)}');
    return true;
  }

  Future<Map<String, dynamic>> extractFaceFeatures(String imagePath) async {
    if (!_isInitialized) {
      await initialize();
    }

    final faces = await detectFaces(imagePath);
    
    if (faces.isEmpty) {
      throw Exception('No face detected in the image');
    }

    if (faces.length > 1) {
      throw Exception('Multiple faces detected. Please use a single face photo');
    }

    final face = faces.first;
    
    // ✅ IMPROVED: Validate face quality
    if (!isValidFaceForRecognition(face)) {
      throw Exception('Face quality insufficient. Please ensure good lighting and look straight at camera');
    }

    final imageFile = File(imagePath);
    final imageBytes = await imageFile.readAsBytes();
    final image = img.decodeImage(imageBytes);
    
    if (image == null) {
      throw Exception('Failed to decode image');
    }

    final enhancedImage = _enhanceImageForLowLight(image);
    final faceImage = _cropFaceWithMargin(enhancedImage, face.boundingBox);
    final embedding = await _getEmbedding(faceImage);

    return _buildTemplate(face, embedding);
  }

  Future<Map<String, dynamic>> buildTemplateFromFace(
    Face face,
    String imagePath,
  ) async {
    if (!_isInitialized) {
      await initialize();
    }

    // ✅ IMPROVED: Validate face quality before processing
    if (!isValidFaceForRecognition(face)) {
      throw Exception('Face quality insufficient');
    }

    final imageFile = File(imagePath);
    final imageBytes = await imageFile.readAsBytes();
    final image = img.decodeImage(imageBytes);
    
    if (image == null) {
      throw Exception('Failed to decode image');
    }

    final enhancedImage = _enhanceImageForLowLight(image);
    final faceImage = _cropFaceWithMargin(enhancedImage, face.boundingBox);
    final embedding = await _getEmbedding(faceImage);

    return _buildTemplate(face, embedding);
  }

  /// Enhance image for low light conditions
  img.Image _enhanceImageForLowLight(img.Image image) {
    int totalBrightness = 0;
    int pixelCount = 0;
    
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final brightness = (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b).toInt();
        totalBrightness += brightness;
        pixelCount++;
      }
    }
    
    final avgBrightness = totalBrightness / pixelCount;
    
    // ✅ IMPROVED: More aggressive enhancement for consistency
    if (avgBrightness < 100) {
      debugPrint('Low light detected (brightness: ${avgBrightness.toStringAsFixed(1)}), enhancing...');
      
      final brightnessFactor = 1.4 + ((100 - avgBrightness) / 180);
      final contrastFactor = 1.25 + ((100 - avgBrightness) / 250);
      
      return img.adjustColor(
        image,
        brightness: brightnessFactor,
        contrast: contrastFactor,
        saturation: 1.15,
      );
    } else if (avgBrightness < 130) {
      debugPrint('Medium-low light (brightness: ${avgBrightness.toStringAsFixed(1)}), slight enhancement...');
      
      return img.adjustColor(
        image,
        brightness: 1.2,
        contrast: 1.15,
        saturation: 1.05,
      );
    }
    
    return img.adjustColor(
      image,
      contrast: 1.08,
    );
  }

  img.Image _cropFaceWithMargin(img.Image image, Rect boundingBox) {
    // ✅ IMPROVED: Slightly larger margin for better context
    const margin = 0.35;
    final marginW = boundingBox.width * margin;
    final marginH = boundingBox.height * margin;

    final x = max(0, (boundingBox.left - marginW).toInt());
    final y = max(0, (boundingBox.top - marginH).toInt());
    final w = min(
      image.width - x,
      (boundingBox.width + 2 * marginW).toInt(),
    );
    final h = min(
      image.height - y,
      (boundingBox.height + 2 * marginH).toInt(),
    );

    final croppedFace = img.copyCrop(image, x: x, y: y, width: w, height: h);
    
    // ✅ IMPROVED: Use lanczos for better quality
    return img.copyResize(
      croppedFace,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.cubic,
    );
  }

  Future<List<double>> _getEmbedding(img.Image faceImage) async {
    final input = _preprocessImage(faceImage);
    final output = List.generate(1, (_) => List<double>.filled(embeddingSize, 0.0));

    _interpreter!.run(input, output);

    final embedding = List<double>.from(output[0]);
    return _normalizeEmbedding(embedding);
  }

  List<List<List<List<double>>>> _preprocessImage(img.Image image) {
    final input = <List<List<List<double>>>>[];
    final batch = <List<List<double>>>[];
    
    for (int y = 0; y < inputSize; y++) {
      final row = <List<double>>[];
      
      for (int x = 0; x < inputSize; x++) {
        final pixel = image.getPixel(x, y);
        
        // Normalize to [-1, 1]
        row.add([
          (pixel.r / 127.5) - 1.0,
          (pixel.g / 127.5) - 1.0,
          (pixel.b / 127.5) - 1.0,
        ]);
      }
      
      batch.add(row);
    }
    
    input.add(batch);
    return input;
  }

  List<double> _normalizeEmbedding(List<double> embedding) {
    double sumSquares = 0.0;
    for (var value in embedding) {
      sumSquares += value * value;
    }
    
    final magnitude = sqrt(sumSquares);
    
    if (magnitude < 1e-6) {
      return embedding;
    }
    
    return embedding.map((value) => value / magnitude).toList();
  }

  Map<String, dynamic> _buildTemplate(Face face, List<double> embedding) {
    final qualityScore = calculateFaceQuality(face);
    
    return {
      'version': 3,
      'embedding': embedding,
      'embeddingSize': embedding.length,
      'qualityScore': qualityScore, // ✅ NEW: Store quality score
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

  // ✅ IMPROVED: More robust comparison with quality weighting
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

    // Calculate cosine similarity
    double dotProduct = 0.0;
    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
    }

    // ✅ IMPROVED: Use raw cosine similarity (already normalized embeddings)
    final cosineSimilarity = dotProduct.clamp(-1.0, 1.0);
    
    // Convert from [-1, 1] to [0, 1]
    final similarity = (cosineSimilarity + 1.0) / 2.0;
    
    // ✅ NEW: Apply quality weighting
    final quality1 = (template1['qualityScore'] as num?)?.toDouble() ?? 0.8;
    final quality2 = (template2['qualityScore'] as num?)?.toDouble() ?? 0.8;
    final avgQuality = (quality1 + quality2) / 2.0;
    
    // Boost similarity if both faces are high quality
    final weightedSimilarity = similarity * (0.7 + avgQuality * 0.3);
    
    return weightedSimilarity.clamp(0.0, 1.0);
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

      // ✅ Use the new validation method
      if (!isValidFaceForRecognition(face)) {
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
        
        if (faceRatio < 0.15) { // ✅ Slightly increased minimum
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
    if (!_isInitialized || _interpreter == null) {
      return {'status': 'not_initialized'};
    }

    return {
      'status': 'initialized',
      'inputSize': inputSize,
      'embeddingSize': embeddingSize,
      'inputShape': _interpreter!.getInputTensor(0).shape,
      'outputShape': _interpreter!.getOutputTensor(0).shape,
    };
  }

  void dispose() {
    _faceDetector.close();
    _interpreter?.close();
    _isInitialized = false;
    debugPrint('FaceRecognitionTFLiteService disposed');
  }
}