import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScaleAccountApp());
}

class ScaleAccountApp extends StatelessWidget {
  const ScaleAccountApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '电子秤拍照记账',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class Record {
  final int? id;
  final String name;
  final double weight;
  final double price;
  final String remark;
  final int createdAt;
  final int isReturn;

  Record({
    this.id,
    required this.name,
    required this.weight,
    required this.price,
    required this.remark,
    required this.createdAt,
    required this.isReturn,
  });

  double get amount {
    final value = weight * price;
    return isReturn == 1 ? -value : value;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'weight': weight,
      'price': price,
      'remark': remark,
      'createdAt': createdAt,
      'isReturn': isReturn,
    };
  }

  factory Record.fromMap(Map<String, dynamic> map) {
    return Record(
      id: map['id'] as int?,
      name: map['name'] as String,
      weight: (map['weight'] as num).toDouble(),
      price: (map['price'] as num).toDouble(),
      remark: map['remark'] as String? ?? '',
      createdAt: map['createdAt'] as int,
      isReturn: map['isReturn'] as int,
    );
  }
}

class Db {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'scale_account.db');

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE records(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            weight REAL NOT NULL,
            price REAL NOT NULL,
            remark TEXT,
            createdAt INTEGER NOT NULL,
            isReturn INTEGER NOT NULL
          )
        ''');
      },
    );

    return _db!;
  }

  static Future<void> insert(Record record) async {
    final db = await database;
    await db.insert('records', record.toMap());
  }

  static Future<List<Record>> all() async {
    final db = await database;
    final rows = await db.query('records', orderBy: 'createdAt DESC');
    return rows.map((e) => Record.fromMap(e)).toList();
  }

  static Future<void> delete(int id) async {
    final db = await database;
    await db.delete('records', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> clear() async {
    final db = await database;
    await db.delete('records');
  }
}

enum FilterType {
  today,
  all,
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final picker = ImagePicker();
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  final nameController = TextEditingController();
  final weightController = TextEditingController();
  final priceController = TextEditingController();
  final remarkController = TextEditingController();

  List<Record> records = [];
  File? photo;
  bool loading = false;
  FilterType filter = FilterType.today;

  @override
  void initState() {
    super.initState();
    loadRecords();
  }

  @override
  void dispose() {
    recognizer.close();
    nameController.dispose();
    weightController.dispose();
    priceController.dispose();
    remarkController.dispose();
    super.dispose();
  }

  Future<void> loadRecords() async {
    final list = await Db.all();
    setState(() {
      records = list;
    });
  }

  List<Record> get filteredRecords {
    if (filter == FilterType.all) return records;

    final now = DateTime.now();

    return records.where((r) {
      final t = DateTime.fromMillisecondsSinceEpoch(r.createdAt);
      return t.year == now.year && t.month == now.month && t.day == now.day;
    }).toList();
  }

  double get totalAmount {
    return filteredRecords.fold(0, (sum, r) => sum + r.amount);
  }

  double get totalWeight {
    return filteredRecords.fold(
      0,
      (sum, r) => sum + (r.isReturn == 1 ? -r.weight : r.weight),
    );
  }

  Future<void> takePhoto() async {
    final status = await Permission.camera.request();

    if (!status.isGranted) {
      showMsg('请允许相机权限');
      return;
    }

    try {
      setState(() {
        loading = true;
      });

      final xfile = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );

      if (xfile == null) {
        setState(() {
          loading = false;
        });
        return;
      }

      final file = File(xfile.path);
      final inputImage = InputImage.fromFile(file);
      final result = await recognizer.processImage(inputImage);
      final weight = extractWeight(result.text);

      setState(() {
        photo = file;
        loading = false;
        if (weight != null) {
          weightController.text = weight.toString();
        }
      });

      if (weight == null) {
        showMsg('未识别到重量，请手动输入');
      } else {
        showMsg('识别重量：$weight 斤');
      }
    } catch (e) {
      setState(() {
        loading = false;
      });
      showMsg('识别失败：$e');
    }
  }

  double? extractWeight(String text) {
    final clean = text.replaceAll(',', '.');
    final reg = RegExp(r'(\d+(\.\d+)?)');
    final nums = reg
        .allMatches(clean)
        .map((m) => double.tryParse(m.group(0) ?? ''))
        .whereType<double>()
        .where((n) => n > 0 && n < 1000)
        .toList();

    if (nums.isEmpty) return null;
    return nums.first;
  }

  Future<void> addRecord({required bool isReturn}) async {
    final name = nameController.text.trim();
    final weight = double.tryParse(weightController.text.trim());
    final price = double.tryParse(priceController.text.trim());
    final remark = remarkController.text.trim();

    if (name.isEmpty) {
      showMsg('请输入货物名称');
      return;
    }

    if (weight == null || weight <= 0) {
      showMsg('请输入正确重量');
      return;
    }

    if (price == null || price < 0) {
      showMsg('请输入正确单价');
      return;
    }

    await Db.insert(
      Record(
        name: name,
        weight: weight,
        price: price,
        remark: remark,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        isReturn: isReturn ? 1 : 0,
      ),
    );

    nameController.clear();
    weightController.clear();
    priceController.clear();
    remarkController.clear();

    setState(() {
      photo = null;
    });

    await loadRecords();
    showMsg(isReturn ? '已添加退货记录' : '已添加销售记录');
  }

  Future<void> deleteRecord(Record r) async {
    if (r.id == null) return;
    await Db.delete(r.id!);
    await loadRecords();
    showMsg('已删除');
  }

  Future<void> clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('确认清空？'),
          content: const Text('所有记录都会被删除，无法恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认清空'),
            ),
          ],
        );
      },
    );

    if (ok == true) {
      await Db.clear();
      await loadRecords();
      showMsg('已清空');
    }
  }

  void useTemplate(String name, double price) {
    nameController.text = name;
    priceController.text = price.toString();
  }

  void showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('MM-dd HH:mm');

    return Scaffold(
      appBar: AppBar(
        title: const Text('电子秤拍照记账'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: clearAll,
            icon: const Icon(Icons.delete_sweep),
          ),
        ],
      ),
      body: Column(
        children: [
          summary(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                cameraCard(),
                const SizedBox(height: 12),
                templates(),
                const SizedBox(height: 12),
                formCard(),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '记账记录',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text('${filteredRecords.length} 条'),
                  ],
                ),
                const SizedBox(height: 8),
                if (filteredRecords.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('暂无记录')),
                  )
                else
                  ...filteredRecords.map((r) {
                    final time =
                        DateTime.fromMillisecondsSinceEpoch(r.createdAt);

                    return Card(
                      child: ListTile(
                        title: Text(
                          '${r.isReturn == 1 ? "退货：" : ""}${r.name}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: r.isReturn == 1 ? Colors.red : null,
                          ),
                        ),
                        subtitle: Text(
                          '${r.weight.toStringAsFixed(2)} 斤 × ${r.price.toStringAsFixed(2)} 元/斤\n'
                          '${dateFormat.format(time)}'
                          '${r.remark.isNotEmpty ? "\n备注：${r.remark}" : ""}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '￥${r.amount.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: r.amount >= 0
                                    ? Colors.green
                                    : Colors.red,
                              ),
                            ),
                            IconButton(
                              onPressed: () => deleteRecord(r),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget summary() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: Colors.green.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(filter == FilterType.today ? '今日合计' : '全部合计'),
          Text(
            '￥${totalAmount.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 30,
              color: Colors.green,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text('重量合计：${totalWeight.toStringAsFixed(2)} 斤'),
          const SizedBox(height: 8),
          SegmentedButton<FilterType>(
            segments: const [
              ButtonSegment(value: FilterType.today, label: Text('今日')),
              ButtonSegment(value: FilterType.all, label: Text('全部')),
            ],
            selected: {filter},
            onSelectionChanged: (v) {
              setState(() {
                filter = v.first;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget cameraCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            if (photo != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  photo!,
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              )
            else
              Container(
                height: 120,
                width: double.infinity,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('请拍摄电子秤显示屏'),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: loading ? null : takePhoto,
                icon: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.camera_alt),
                label: Text(loading ? '识别中...' : '拍照识别重量'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget templates() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '快捷商品',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              label: const Text('土豆 2.5元/斤'),
              onPressed: () => useTemplate('土豆', 2.5),
            ),
            ActionChip(
              label: const Text('大葱 3.5元/斤'),
              onPressed: () => useTemplate('大葱', 3.5),
            ),
            ActionChip(
              label: const Text('白菜 1.8元/斤'),
              onPressed: () => useTemplate('白菜', 1.8),
            ),
            ActionChip(
              label: const Text('苹果 5元/斤'),
              onPressed: () => useTemplate('苹果', 5),
            ),
          ],
        ),
      ],
    );
  }

  Widget formCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '货物名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: weightController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '重量',
                suffixText: '斤',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: priceController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '单价',
                suffixText: '元/斤',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: remarkController,
              decoration: const InputDecoration(
                labelText: '备注，可选',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => addRecord(isReturn: false),
                    child: const Text('添加销售'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => addRecord(isReturn: true),
                    child: const Text('退货'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
