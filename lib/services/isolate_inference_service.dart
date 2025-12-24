import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Request object to send to Isolate
class InferenceRequest {
  final int requestId;
  final String imagePath;
  final Map<String, dynamic> faceData; // Bounding box, landmarks, etc.
  final bool allowSidePose;

  InferenceRequest({
    required this.requestId,
    required this.imagePath,
    required this.faceData,
    this.allowSidePose = false,
  });
}

/// Response object from Isolate
class InferenceResponse {
  final int requestId;
  final List<double>? embedding;
  final double? qualityScore;
  final String? error;

  InferenceResponse({
    required this.requestId,
    this.embedding,
    this.qualityScore,
    this.error,
  });
}

class IsolateInferenceService {
  static final IsolateInferenceService _instance = IsolateInferenceService._internal();

  factory IsolateInferenceService() {
    return _instance;
  }

  IsolateInferenceService._internal();

  Isolate? _isolate;
  SendPort? _sendPort;
  
  // We don't need a StreamController here if we are just using Completers map
  bool _isInitialized = false;
  int _requestIdCounter = 0;
  final Map<int, Completer<InferenceResponse>> _activeRequests = {};
  Completer<void>? _initCompleter;

  Future<void> initialize() async {
    if (_isInitialized) return;
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }
    _initCompleter = Completer<void>();

    try {
      final receivePort = ReceivePort();
      final rootIsolateToken = RootIsolateToken.instance;
      
      // Load model bytes in main isolate
      final modelData = await rootBundle.load('assets/models/mobile_face_net.tflite');
      final modelBytes = modelData.buffer.asUint8List();

      _isolate = await Isolate.spawn(
        _isolateEntryPoint,
        _IsolateInitData(
          receivePort.sendPort,
          rootIsolateToken!,
          modelBytes,
        ),
      );

      // Listen to the port - this handles BOTH the initial SendPort and subsequent responses
      receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          _isInitialized = true;
          _initCompleter?.complete();
        } else if (message is InferenceResponse) {
          final completer = _activeRequests.remove(message.requestId);
          if (completer != null) {
            completer.complete(message);
          }
        }
      });
      
      await _initCompleter!.future;
      
    } catch (e) {
      _initCompleter?.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  Future<InferenceResponse> processFace({
    required String imagePath,
    required Map<String, dynamic> faceData,
    bool allowSidePose = false,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final requestId = _requestIdCounter++;
    final completer = Completer<InferenceResponse>();
    _activeRequests[requestId] = completer;

    _sendPort!.send(InferenceRequest(
      requestId: requestId,
      imagePath: imagePath,
      faceData: faceData,
      allowSidePose: allowSidePose,
    ));

    return completer.future;
  }

  void dispose() {
    _isolate?.kill();
    _isInitialized = false;
    _initCompleter = null;
  }
}

class _IsolateInitData {
  final SendPort sendPort;
  final RootIsolateToken rootToken;
  final Uint8List modelBytes;

  _IsolateInitData(this.sendPort, this.rootToken, this.modelBytes);
}

// Global function for Isolate entry point
Future<void> _isolateEntryPoint(_IsolateInitData initData) async {
  // Initialize services inside isolate (needed for some plugins, though maybe not for loading from buffer)
  BackgroundIsolateBinaryMessenger.ensureInitialized(initData.rootToken);

  final receivePort = ReceivePort();
  initData.sendPort.send(receivePort.sendPort);

  // Load Model from buffer
  Interpreter? interpreter;
  int inputSize = 112; 
  int embeddingSize = 192;
  
  try {
    // Determine the buffer length and address if necessary, or just copy it.
    // TFLite Flutter's fromBuffer accepts Uint8List directly.
    interpreter = Interpreter.fromBuffer(
      initData.modelBytes,
      options: InterpreterOptions()..threads = 4,
    );
    
     // Update shapes
    final inputShape = interpreter.getInputTensor(0).shape;
    final outputShape = interpreter.getOutputTensor(0).shape;
    if (inputShape.length >= 3) inputSize = inputShape[1];
    if (outputShape.length >= 2) embeddingSize = outputShape[1];
    
  } catch (e) {
    print('ISOLATE: Failed to load model: $e');
  }

  receivePort.listen((message) async {
    if (message is InferenceRequest) {
      try {
        if (interpreter == null) {
          throw Exception('Model not initialized');
        }

        final imageFile = File(message.imagePath);
        if (!await imageFile.exists()) {
           throw Exception('Image file not found: ${message.imagePath}');
        }
        
        final imageBytes = await imageFile.readAsBytes();
        final image = img.decodeImage(imageBytes);

        if (image == null) {
          throw Exception('Failed to decode image');
        }

        // Process
        final enhancedImage = _enhanceImage(image);
        final alignedImage = _alignFace(enhancedImage, message.faceData);
        final faceImage = _cropFace(alignedImage, message.faceData, inputSize);
        final embedding = _runInference(interpreter, faceImage, inputSize, embeddingSize);
        
        initData.sendPort.send(InferenceResponse(
          requestId: message.requestId,
          embedding: embedding,
          qualityScore: 1.0, 
        ));

      } catch (e) {
        initData.sendPort.send(InferenceResponse(
          requestId: message.requestId,
          error: e.toString(),
        ));
      }
    }
  });
}

// --- Helper Functions in Isolate ---

img.Image _enhanceImage(img.Image image) {
  return img.adjustColor(
    image,
    brightness: 1.1,
    contrast: 1.15,
    saturation: 1.05,
    gamma: 1.1,
  );
}

img.Image _alignFace(img.Image image, Map<String, dynamic> faceData) {
  try {
    final landmarks = faceData['landmarks'] as Map<String, dynamic>?;
    if (landmarks == null) return image;

    // Expecting keys like 'leftEye' and 'rightEye' with 'x','y'
    final leftEye = landmarks['leftEye'];
    final rightEye = landmarks['rightEye'];

    if (leftEye == null || rightEye == null) return image;
    
    // Explicitly cast to Map<String, dynamic> or access safely
    // Assuming passed structure is {'x': double, 'y': double}
    final lx = (leftEye['x'] as num).toDouble();
    final ly = (leftEye['y'] as num).toDouble();
    final rx = (rightEye['x'] as num).toDouble();
    final ry = (rightEye['y'] as num).toDouble();

    final dx = rx - lx;
    final dy = ry - ly;

    final angleRad = atan2(dy, dx);
    final angleDeg = angleRad * 180 / pi;

    if (angleDeg.abs() > 2.0) {
      return img.copyRotate(image, angle: -angleDeg, interpolation: img.Interpolation.cubic);
    }
    return image;
  } catch (e) {
    return image;
  }
}

img.Image _cropFace(img.Image image, Map<String, dynamic> faceData, int inputSize) {
  final box = faceData['boundingBox'] as Map<String, dynamic>;
  final left = (box['left'] as num).toDouble();
  final top = (box['top'] as num).toDouble();
  final width = (box['width'] as num).toDouble();
  final height = (box['height'] as num).toDouble();

  const margin = 0.35;
  final marginW = width * margin;
  final marginH = height * margin;

  final x = max(0, (left - marginW).toInt());
  final y = max(0, (top - marginH).toInt());
  final w = min(image.width - x, (width + 2 * marginW).toInt());
  final h = min(image.height - y, (height + 2 * marginH).toInt());

  final croppedFace = img.copyCrop(image, x: x, y: y, width: w, height: h);
  
  return img.copyResize(
    croppedFace,
    width: inputSize,
    height: inputSize,
    interpolation: img.Interpolation.cubic,
  );
}

List<double> _runInference(Interpreter interpreter, img.Image faceImage, int inputSize, int embeddingSize) {
  final input = _preprocessImage(faceImage, inputSize);
  final output = List.generate(1, (_) => List<double>.filled(embeddingSize, 0.0));

  interpreter.run(input, output);

  final embedding = List<double>.from(output[0]);
  return _normalizeEmbedding(embedding);
}

List<List<List<List<double>>>> _preprocessImage(img.Image image, int inputSize) {
  final input = <List<List<List<double>>>>[];
  final batch = <List<List<double>>>[];
  
  for (int y = 0; y < inputSize; y++) {
    final row = <List<double>>[];
    for (int x = 0; x < inputSize; x++) {
      final pixel = image.getPixel(x, y);
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
  if (magnitude < 1e-6) return embedding;
  return embedding.map((value) => value / magnitude).toList();
}
