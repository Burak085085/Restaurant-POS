// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'advanced_features.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'storage.dart';

final GlobalKey<ScaffoldMessengerState> appMessengerKey = GlobalKey<ScaffoldMessengerState>();
const int kTableCount = 20;
const String kStoreKey = 'restaurant_pos_v2';
const Color ink = Color(0xFF1B2733), bg = Color(0xFFEEF1F4), green = Color(0xFF23845B), red = Color(0xFFC7443B), amber = Color(0xFFE39A1C);
String money(int cents) {
  final isNegative = cents < 0;
  final absoluteCents = cents.abs();
  final whole = absoluteCents ~/ 100;
  final fractional = (absoluteCents % 100).toString().padLeft(2, '0');
  return '${isNegative ? '-' : ''}$whole,$fractional ₼';
}
int? parseMoney(String input, {bool allowZero = false}) {
  var value = input.trim().replaceAll('₼', '').replaceAll(RegExp(r'[\s\u00a0\u202f]'), '');
  if (value.isEmpty) return null;
  if (value.startsWith('+')) value = value.substring(1);
  if (value.isEmpty || value.startsWith('-')) return null;

  String whole;
  String fraction = '';
  final hasComma = value.contains(',');
  final hasDot = value.contains('.');
  String? decimalSeparator;
  String? groupingSeparator;

  if (hasComma && hasDot) {
    decimalSeparator = value.lastIndexOf(',') > value.lastIndexOf('.') ? ',' : '.';
    groupingSeparator = decimalSeparator == ',' ? '.' : ',';
  } else if (hasComma || hasDot) {
    final separator = hasComma ? ',' : '.';
    final pieces = value.split(separator);
    if (pieces.any((piece) => piece.isEmpty)) return null;
    if (pieces.length > 2) {
      if (pieces.first.isEmpty || pieces.first.length > 3 ||
          pieces.skip(1).any((piece) => piece.length != 3 || !RegExp(r'^\d{3}$').hasMatch(piece))) return null;
      groupingSeparator = separator;
    } else if (pieces.last.length == 3 && pieces.first.length <= 3) {
      groupingSeparator = separator;
    } else {
      decimalSeparator = separator;
    }
  }

  if (decimalSeparator != null) {
    final pieces = value.split(decimalSeparator);
    if (pieces.length != 2 || pieces.last.isEmpty || pieces.last.length > 2 ||
        !RegExp(r'^\d+$').hasMatch(pieces.last)) return null;
    whole = pieces.first;
    fraction = pieces.last.padRight(2, '0');
  } else {
    whole = value;
  }

  if (groupingSeparator != null) {
    final groups = whole.split(groupingSeparator);
    if (groups.length < 2 || groups.first.isEmpty || groups.first.length > 3 ||
        !RegExp(r'^\d+$').hasMatch(groups.first) ||
        groups.skip(1).any((group) => group.length != 3 || !RegExp(r'^\d{3}$').hasMatch(group))) return null;
    whole = groups.join();
  }
  if (!RegExp(r'^\d+$').hasMatch(whole)) return null;
  final wholeValue = int.tryParse(whole);
  if (wholeValue == null || wholeValue > 10000000) return null;
  final cents = wholeValue * 100 + (fraction.isEmpty ? 0 : int.parse(fraction));
  if (cents > 1000000000 || (cents == 0 && !allowZero)) return null;
  return cents;
}
DateTime azNow() => DateTime.now().toUtc();
DateTime azWallTime(DateTime instant) => instant.toUtc().add(const Duration(hours: 4));
DateTime bakuWallTimeToUtc(DateTime wallTime) => DateTime.utc(
  wallTime.year, wallTime.month, wallTime.day, wallTime.hour, wallTime.minute,
  wallTime.second, wallTime.millisecond, wallTime.microsecond,
).subtract(const Duration(hours: 4));
String bakuTimestamp(String value) {
  final parsed = DateTime.tryParse(value);
  return parsed == null ? value : stamp(azWallTime(parsed));
}
String _legacyBakuTimestamp(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  return DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour,
    parsed.minute, parsed.second, parsed.millisecond, parsed.microsecond)
      .subtract(const Duration(hours: 4)).toIso8601String();
}
void _migrateLegacyTimestamps(Map<String, dynamic> data) {
  void migrateRows(Object? source, String field) {
    if (source is! List) return;
    for (final row in source) {
      if (row is Map && row[field] is String && (row[field] as String).isNotEmpty) {
        row[field] = _legacyBakuTimestamp(row[field] as String);
      }
    }
  }
  migrateRows(data['audit'], 'at');
  migrateRows(data['stockMovements'], 'at');
  migrateRows(data['cashMovements'], 'at');
  migrateRows(data['registerSessions'], 'openedAt');
  if (data['registerSessions'] is List) {
    for (final row in data['registerSessions'] as List) {
      if (row is Map && row['closedAt'] is String && (row['closedAt'] as String).isNotEmpty) {
        row['closedAt'] = _legacyBakuTimestamp(row['closedAt'] as String);
      }
    }
  }
  final advanced = data['advanced'];
  if (advanced is Map) {
    migrateRows(advanced['purchases'], 'at');
    migrateRows(advanced['reservations'], 'dateTime');
  }
}
String dayKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String stamp(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class RecipeLine {
  final String ingredientId;
  final int quantity;
  const RecipeLine({required this.ingredientId, required this.quantity});
  Map<String, dynamic> toJson() => {'ingredientId': ingredientId, 'quantity': quantity};
  factory RecipeLine.fromJson(Map<String, dynamic> json) =>
      RecipeLine(ingredientId: json['ingredientId'] ?? '', quantity: json['quantity'] ?? 0);
}
class Ingredient {
  final String id;
  String name, unit;
  int stock, lowAt, costPerUnit;
  Ingredient({required this.id, required this.name, required this.unit,
    required this.stock, required this.lowAt, required this.costPerUnit});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'unit': unit,
    'stock': stock, 'lowAt': lowAt, 'costPerUnit': costPerUnit};
  factory Ingredient.fromJson(Map<String, dynamic> json) => Ingredient(
    id: json['id'] ?? '', name: json['name'] ?? '', unit: json['unit'] ?? 'adet',
    stock: json['stock'] ?? 0, lowAt: json['lowAt'] ?? 0,
    costPerUnit: json['costPerUnit'] ?? 0);
}
class Product {
  String id, category, name; int price, costPrice, stock, lowAt; bool active;
  Product(this.id,this.category,this.name,this.price,{this.costPrice=0,this.stock=100,this.lowAt=5,this.active=true});
  Map<String,dynamic> toJson()=>{'id':id,'category':category,'name':name,'price':price,'costPrice':costPrice,'stock':stock,'lowAt':lowAt,'active':active};
  factory Product.fromJson(Map<String,dynamic> j)=>Product(j['id']??'',j['category']??'Genel',j['name']??'',j['price']??0,costPrice:j['costPrice']??0,stock:j['stock']??100,lowAt:j['lowAt']??5,active:j['active']??true);
}
enum KitchenState { queued, preparing, ready, served }
class OrderLine {
  String productId, name;
  int price, qty, unitCost;
  bool sent;
  KitchenState kitchen;
  OrderLine(this.productId, this.name, this.price, this.qty,
      {this.sent = false, this.kitchen = KitchenState.queued, this.unitCost = 0});
  Map<String, dynamic> toJson() => {'productId': productId, 'name': name,
    'price': price, 'qty': qty, 'sent': sent, 'kitchen': kitchen.index, 'unitCost': unitCost};
  factory OrderLine.fromJson(Map<String, dynamic> j) => OrderLine(
    j['productId'] ?? '', j['name'] ?? '', j['price'] ?? 0, j['qty'] ?? 0,
    sent: j['sent'] ?? true,
    kitchen: KitchenState.values[(j['kitchen'] ?? 0).clamp(0, 3).toInt()], unitCost: j['unitCost'] ?? 0,
  );
}
class PosTable { int id; List<OrderLine> items=[]; KitchenState kitchen=KitchenState.queued; int discount=0; bool discountPercent=false; String discountReason=''; PosTable(this.id); int get subtotal=>items.fold(0,(s,e)=>s+e.price*e.qty); int get total=> (subtotal-(discountPercent?subtotal*discount~/100:discount)).clamp(0,1<<30).toInt(); Map<String,dynamic> toJson()=>{'id':id,'items':items.map((e)=>e.toJson()).toList(),'kitchen':kitchen.index,'discount':discount,'discountPercent':discountPercent,'discountReason':discountReason}; }
KitchenState tableKitchenState(PosTable table) {
  final active = table.items.where((line) => line.sent && line.kitchen != KitchenState.served);
  if (active.any((line) => line.kitchen == KitchenState.queued)) return KitchenState.queued;
  if (active.any((line) => line.kitchen == KitchenState.preparing)) return KitchenState.preparing;
  if (active.any((line) => line.kitchen == KitchenState.ready)) return KitchenState.ready;
  return KitchenState.served;
}

String kitchenLabel(PosTable table) {
  if (table.items.isEmpty) return 'Boş';
  if (table.items.any((line) => !line.sent)) return 'Gönderilmemiş';
  switch (tableKitchenState(table)) {
    case KitchenState.queued: return 'Kuyruk';
    case KitchenState.preparing: return 'Hazırlanıyor';
    case KitchenState.ready: return 'Hazır';
    case KitchenState.served: return 'Servis edildi';
  }
}

class PaymentPart { String method; int amount; int tendered; PaymentPart(this.method,this.amount,{int? tendered}):tendered=tendered??amount; int get change=>method=='Nakit'?(tendered-amount).clamp(0,1<<30).toInt():0; bool get isValid => amount > 0 && (method == 'Nakit' ? tendered >= amount : method == 'Kart' && tendered == amount); Map<String,dynamic> toJson()=>{'method':method,'amount':amount,'tendered':tendered}; }
class RegisterSession {
  int id;
  String openedAt;
  String? closedAt;
  int openingCash;
  int? closingCash;
  int? expectedCash;
  String note;
  RegisterSession({required this.id, required this.openedAt, required this.openingCash,
    this.closedAt, this.closingCash, this.expectedCash, this.note = ''});
  bool get isOpen => closedAt == null;
  Map<String, dynamic> toJson() => {
    'id': id, 'openedAt': openedAt, 'closedAt': closedAt,
    'openingCash': openingCash, 'closingCash': closingCash,
    'expectedCash': expectedCash, 'note': note,
  };
  factory RegisterSession.fromJson(Map<String, dynamic> j) => RegisterSession(
    id: j['id'] ?? 0, openedAt: j['openedAt'] ?? '',
    openingCash: j['openingCash'] ?? 0, closedAt: j['closedAt'],
    closingCash: j['closingCash'], expectedCash: j['expectedCash'],
    note: j['note'] ?? '',
  );
}
class CashMovement {
  int id, sessionId, amount;
  String at, type, note;
  CashMovement({required this.id, required this.sessionId, required this.at,
    required this.type, required this.amount, required this.note});
  Map<String, dynamic> toJson() => {
    'id': id, 'sessionId': sessionId, 'at': at,
    'type': type, 'amount': amount, 'note': note,
  };
  factory CashMovement.fromJson(Map<String, dynamic> j) => CashMovement(
    id: j['id'] ?? 0, sessionId: j['sessionId'] ?? 0,
    at: j['at'] ?? '', type: j['type'] ?? '',
    amount: j['amount'] ?? 0, note: j['note'] ?? '',
  );
}
class Sale { String date,time,staff; int table,total,discount; List<OrderLine> items; List<PaymentPart> payments; int? registerSessionId; bool isRefund,stockReturned,discountPercent; int? refundOfSaleIndex; String reason,discountReason; Map<String,int>? ingredientUsage; Sale(this.date,this.time,this.staff,this.table,this.total,this.discount,this.items,this.payments,{this.registerSessionId,this.isRefund=false,this.refundOfSaleIndex,this.reason='',this.stockReturned=false,this.ingredientUsage,this.discountReason='',this.discountPercent=false}); Map<String,dynamic> toJson()=>{'date':date,'time':time,'staff':staff,'table':table,'total':total,'discount':discount,'discountReason':discountReason,'discountPercent':discountPercent,'registerSessionId':registerSessionId,'items':items.map((e)=>e.toJson()).toList(),'payments':payments.map((e)=>e.toJson()).toList(),'isRefund':isRefund,'refundOfSaleIndex':refundOfSaleIndex,'reason':reason,'stockReturned':stockReturned,'ingredientUsage':ingredientUsage}; factory Sale.fromJson(Map<String,dynamic> j)=>Sale(j['date']??'',j['time']??'',j['staff']??'Admin',j['table']??0,j['total']??0,j['discount']??0,(j['items'] as List? ?? []).map((e)=>OrderLine.fromJson(Map<String,dynamic>.from(e))).toList(),(j['payments'] as List? ?? []).map((e)=>PaymentPart(e['method']??'Nakit',e['amount']??0,tendered:e['tendered']??e['amount']??0)).toList(),registerSessionId:j['registerSessionId'],isRefund:j['isRefund']??false,refundOfSaleIndex:j['refundOfSaleIndex'],reason:j['reason']??'',stockReturned:j['stockReturned']??false,ingredientUsage:j['ingredientUsage'] is Map ? Map<String,int>.from(j['ingredientUsage'] as Map) : null,discountReason:j['discountReason']??'',discountPercent:j['discountPercent']??false); }
class Expense { final int id,amount; final String date,category,note; Expense({required this.id,required this.amount,required this.date,required this.category,required this.note}); Map<String,dynamic> toJson()=>{'id':id,'amount':amount,'date':date,'category':category,'note':note}; factory Expense.fromJson(Map<String,dynamic> j)=>Expense(id:j['id']??0,amount:j['amount']??0,date:j['date']??'',category:j['category']??'Diğer',note:j['note']??''); }
class StockMovement { final int id,quantity,beforeStock,afterStock,productCost; final String productId,productName,type,at,note; StockMovement({required this.id,required this.productId,required this.productName,required this.type,required this.quantity,required this.beforeStock,required this.afterStock,required this.productCost,required this.at,required this.note}); Map<String,dynamic> toJson()=>{'id':id,'productId':productId,'productName':productName,'type':type,'quantity':quantity,'beforeStock':beforeStock,'afterStock':afterStock,'productCost':productCost,'at':at,'note':note}; factory StockMovement.fromJson(Map<String,dynamic> j)=>StockMovement(id:j['id']??0,productId:j['productId']??'',productName:j['productName']??'',type:j['type']??'',quantity:j['quantity']??0,beforeStock:j['beforeStock']??0,afterStock:j['afterStock']??0,productCost:j['productCost']??0,at:j['at']??'',note:j['note']??''); }
class Staff {
  static const int _pinIterations = 120000;
  static const String _pinPrefix = 'pbkdf2-sha256\$$_pinIterations\$';
  String name, role, salt, pinHash;
  bool active, pinRequired;
  Staff(this.name, this.role, {String pin='1234', String? salt, String? pinHash, this.active=true, bool? pinRequired})
      : pinRequired = pinRequired ?? true,
        salt = salt ?? _newPinSalt(),
        pinHash = pinHash ?? '' {
    if (pinHash == null) this.pinHash = _derivePinHash(this.salt, pin);
  }
  Staff._(this.name, this.role, this.salt, this.pinHash, this.active, this.pinRequired);
  static String _newPinSalt() { final random=math.Random.secure(); return List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2,'0')).join(); }
  static String _legacyHash(String salt, String pin) => sha256.convert(utf8.encode('$salt:$pin')).toString();
  static String _derivePinHash(String salt, String pin) {
    final hmac = Hmac(sha256, utf8.encode(pin));
    final saltBytes = utf8.encode(salt);
    var u = hmac.convert([...saltBytes, 0, 0, 0, 1]).bytes;
    final output = List<int>.from(u);
    for (var round = 1; round < _pinIterations; round++) {
      u = hmac.convert(u).bytes;
      for (var i = 0; i < output.length; i++) {
        output[i] ^= u[i];
      }
    }
    return '$_pinPrefix${output.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
  }
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
  void setPin(String pin) { salt=_newPinSalt(); pinHash=_derivePinHash(salt,pin); pinRequired=true; }
  bool verifyPin(String candidate) {
    if (!pinRequired) return false;
    if (pinHash.startsWith(_pinPrefix)) {
      return _constantTimeEquals(pinHash, _derivePinHash(salt, candidate));
    }
    if (_constantTimeEquals(pinHash, _legacyHash(salt, candidate))) {
      setPin(candidate);
      return true;
    }
    return false;
  }
  Map<String,dynamic> toJson()=>{'name':name,'role':role,'salt':salt,'pinHash':pinHash,'pinRequired':pinRequired,'active':active};
  factory Staff.fromJson(Map<String,dynamic> j) {
    final name = j['name'] ?? 'Personel';
    final role = j['role'] ?? 'Garson';
    final salt = j['salt']?.toString();
    final hash = j['pinHash']?.toString();
    final pinRequired = j['pinRequired'] is bool ? j['pinRequired'] as bool : role != 'Garson';
    if (salt != null && hash != null) return Staff._(name, role, salt, hash, j['active'] ?? true, pinRequired);
    return Staff(name, role, pin: (j['pin'] ?? '1234').toString(), active: j['active'] ?? true, pinRequired: pinRequired);
  }
}
class KitchenNotice { final int id,tableId,quantity; final String at,productName,reason,by; bool acknowledged; KitchenNotice({required this.id,required this.tableId,required this.quantity,required this.at,required this.productName,required this.reason,required this.by,this.acknowledged=false}); Map<String,dynamic> toJson()=>{'id':id,'tableId':tableId,'quantity':quantity,'at':at,'productName':productName,'reason':reason,'by':by,'acknowledged':acknowledged}; factory KitchenNotice.fromJson(Map<String,dynamic> j)=>KitchenNotice(id:j['id']??0,tableId:j['tableId']??0,quantity:j['quantity']??0,at:j['at']??'',productName:j['productName']??'',reason:j['reason']??'',by:j['by']??'',acknowledged:j['acknowledged']??false); }
class Audit { String at,user,action,detail; Audit(this.at,this.user,this.action,this.detail); Map<String,dynamic> toJson()=>{'at':at,'user':user,'action':action,'detail':detail}; factory Audit.fromJson(Map<String,dynamic> j)=>Audit(j['at']??'',j['user']??'',j['action']??'',j['detail']??''); }

class Pos extends ChangeNotifier {
  List<Product> products=[Product('p1','Dönerler','Tavuk döner',300),Product('p2','Dönerler','Dana döner',500),Product('p3','Dönerler','Dürüm döner',400),Product('p4','Dönerler','Porsiyon döner',700),Product('p5','İçecekler','Kola',200),Product('p6','İçecekler','Fanta',200),Product('p7','İçecekler','Ayran',100),Product('p8','İçecekler','Su',50),Product('p9','Ekstra','Patates',200),Product('p10','Ekstra','Ketçap',50),Product('p11','Ekstra','Mayonez',50)];
  List<PosTable> tables=List.generate(kTableCount,(i)=>PosTable(i+1)); List<Sale> sales=[]; List<RegisterSession> registerSessions=[]; List<CashMovement> cashMovements=[]; List<Expense> expenses=[]; List<StockMovement> stockMovements=[]; List<Ingredient> ingredients=[]; Map<String,List<RecipeLine>> recipes={}; List<Staff> staff=[Staff('Admin','Yönetici')]; List<Audit> audit=[]; List<KitchenNotice> kitchenNotices=[]; String currentUser='Admin';
  List<SupplierRecord> suppliers=[]; List<PurchaseRecord> purchases=[]; List<CustomerRecord> customers=[]; List<ReservationRecord> reservations=[]; Map<String,String> productBarcodes={}; Map<String,Map<String,dynamic>> pinSecurity={}; bool recoveryRequired=false; final StoreRepository _repository; Future<void> _queue=Future.value();
  Pos({StoreRepository? repository}) : _repository = repository ?? SqliteStoreRepository();
  Future<void> load() async { final raw=await _repository.read(); if(raw==null)return; try { final j=jsonDecode(raw) as Map<String,dynamic>; final needsTimestampMigration=(j['timestampFormatVersion'] as num?)?.toInt()!=2; if(needsTimestampMigration)_migrateLegacyTimestamps(j); pinSecurity=(j['pinSecurity'] as Map? ?? {}).map((key,value)=>MapEntry(key.toString(),Map<String,dynamic>.from(value as Map))); products=(j['products'] as List? ?? []).map((e)=>Product.fromJson(Map<String,dynamic>.from(e))).toList(); tables=List.generate(kTableCount,(i)=>PosTable(i+1)); for(final x in (j['tables'] as List? ?? [])){final m=Map<String,dynamic>.from(x); final id=m['id'] as int; if(id<1||id>kTableCount)continue; final t=tables[id-1]; t.items=(m['items'] as List? ?? []).map((e)=>OrderLine.fromJson(Map<String,dynamic>.from(e))).toList(); t.kitchen=KitchenState.values[(m['kitchen']??0).clamp(0,3).toInt()]; final rawItems=(m['items'] as List? ?? []); for(var lineIndex=0;lineIndex<t.items.length;lineIndex++){final rawLine=Map<String,dynamic>.from(rawItems[lineIndex]);if(!rawLine.containsKey('kitchen'))t.items[lineIndex].kitchen=t.kitchen;} t.discount=m['discount']??0;t.discountPercent=m['discountPercent']??false;t.discountReason=m['discountReason']??'';} sales=(j['sales'] as List? ?? []).map((e)=>Sale.fromJson(Map<String,dynamic>.from(e))).toList(); expenses=(j['expenses'] as List? ?? []).map((e)=>Expense.fromJson(Map<String,dynamic>.from(e))).toList(); stockMovements=(j['stockMovements'] as List? ?? []).map((e)=>StockMovement.fromJson(Map<String,dynamic>.from(e))).toList(); ingredients=(j['ingredients'] as List? ?? []).map((e)=>Ingredient.fromJson(Map<String,dynamic>.from(e))).toList(); recipes=(j['recipes'] as Map? ?? {}).map((key,value)=>MapEntry(key.toString(),(value as List).map((e)=>RecipeLine.fromJson(Map<String,dynamic>.from(e))).toList())); registerSessions=(j['registerSessions'] as List? ?? []).map((e)=>RegisterSession.fromJson(Map<String,dynamic>.from(e))).toList(); cashMovements=(j['cashMovements'] as List? ?? []).map((e)=>CashMovement.fromJson(Map<String,dynamic>.from(e))).toList(); final legacyStaff=(j['staff'] as List? ?? []).map((e)=>Staff.fromJson(Map<String,dynamic>.from(e))).toList(); final admins=legacyStaff.where((member)=>member.name=='Admin').toList(); final admin=admins.isNotEmpty ? admins.first : Staff('Admin','Yönetici'); admin.active=true; final names=<String>{'admin'}; staff=[admin,...legacyStaff.where((member)=>member.name!='Admin'&&member.name.trim().isNotEmpty&&names.add(member.name.trim().toLowerCase()))]; audit=(j['audit'] as List? ?? []).map((e)=>Audit.fromJson(Map<String,dynamic>.from(e))).toList(); kitchenNotices=(j['kitchenNotices'] as List? ?? []).map((e)=>KitchenNotice.fromJson(Map<String,dynamic>.from(e))).toList(); final advanced=Map<String,dynamic>.from(j['advanced'] as Map? ?? {}); suppliers=(advanced['suppliers'] as List? ?? []).map((e)=>SupplierRecord.fromJson(Map<String,dynamic>.from(e))).toList(); purchases=(advanced['purchases'] as List? ?? []).map((e)=>PurchaseRecord.fromJson(Map<String,dynamic>.from(e))).toList(); customers=(advanced['customers'] as List? ?? []).map((e)=>CustomerRecord.fromJson(Map<String,dynamic>.from(e))).toList(); reservations=(advanced['reservations'] as List? ?? []).map((e)=>ReservationRecord.fromJson(Map<String,dynamic>.from(e))).toList(); productBarcodes=Map<String,String>.from(advanced['barcodes'] as Map? ?? {}); currentUser='Admin'; recoveryRequired=false; if(needsTimestampMigration){await _repository.write(_snapshot());} } catch (_) { await _repository.backupCorrupt(raw); recoveryRequired=true; } }

  String _snapshot() => jsonEncode({
    'timestampFormatVersion': 2,
    'products': products.map((e) => e.toJson()).toList(),
    'tables': tables.map((e) => e.toJson()).toList(),
    'sales': sales.map((e) => e.toJson()).toList(),
    'expenses': expenses.map((e) => e.toJson()).toList(),
    'stockMovements': stockMovements.map((e) => e.toJson()).toList(),
    'ingredients': ingredients.map((e) => e.toJson()).toList(),
    'recipes': recipes.map((key, value) => MapEntry(key, value.map((e) => e.toJson()).toList())),
    'registerSessions': registerSessions.map((e) => e.toJson()).toList(),
    'cashMovements': cashMovements.map((e) => e.toJson()).toList(),
    'staff': staff.map((e) => e.toJson()).toList(),
    'pinSecurity': pinSecurity,
    'audit': audit.map((e) => e.toJson()).toList(),
    'kitchenNotices': kitchenNotices.map((e) => e.toJson()).toList(),
    'currentUser': currentUser,
    'advanced': {'suppliers': suppliers.map((e)=>e.toJson()).toList(), 'purchases': purchases.map((e)=>e.toJson()).toList(), 'customers': customers.map((e)=>e.toJson()).toList(), 'reservations': reservations.map((e)=>e.toJson()).toList(), 'barcodes': productBarcodes},
  });

  Future<String> exportBackup() => _repository.writeManualBackup(_snapshot());
  Future<List<BackupFile>> listBackups() => _repository.listBackups();
  Future<String?> readBackup(String name) => _repository.readBackup(name);

  Future<bool> restoreBackup(String payload) async {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return false;
      for (final key in ['products', 'tables', 'sales', 'staff']) {
        if (decoded[key] is! List) return false;
      }
      final staffRecords = decoded['staff'] as List;
      final adminRecords = staffRecords.where((entry) =>
          entry is Map && entry['name'] == 'Admin').toList();
      if (adminRecords.isEmpty) return false;
      final adminRecord = Map<String, dynamic>.from(adminRecords.first as Map);
      final hasHashedPin = adminRecord['salt'] is String &&
          (adminRecord['salt'] as String).isNotEmpty &&
          adminRecord['pinHash'] is String &&
          (adminRecord['pinHash'] as String).isNotEmpty;
      final hasLegacyPin = adminRecord['pin'] is String &&
          (adminRecord['pin'] as String).isNotEmpty;
      if (!hasHashedPin && !hasLegacyPin) return false;

      final candidateRepository = MemoryStoreRepository(value: payload);
      final candidate = Pos(repository: candidateRepository);
      await candidate.load();
      if (candidate.recoveryRequired || candidateRepository.corruptBackup != null) return false;
      final candidateIssues = await candidate.integrityCheck();
      if (candidateIssues.isNotEmpty) return false;

      await _repository.backupBeforeRestore(_snapshot());
      await _repository.write(candidate._snapshot());
      await load();
      log('Yedek geri yüklendi', 'Yerel yedek dosyasından veriler geri yüklendi');
      save();
      await flush();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> integrityCheck() async {
    final issues = <String>[];
    final productIds = products.map((item) => item.id).toSet();
    if (productIds.length != products.length) issues.add('Ürün kimlikleri tekrar ediyor.');
    for (final product in products) {
      if (product.stock < 0 || product.price < 0 || product.costPrice < 0) {
        issues.add('${product.name}: stok veya fiyat değeri negatif.');
      }
    }
    if (tables.length != kTableCount || tables.map((table) => table.id).toSet().length != kTableCount) {
      issues.add('Masa kayıtları eksik veya yinelenmiş.');
    }
    for (final table in tables) {
      for (final line in table.items) {
        if (line.qty <= 0) issues.add('Masa ${table.id}: geçersiz ürün adedi.');
        if (!productIds.contains(line.productId)) issues.add('Masa ${table.id}: ürün kaydı bulunamıyor (${line.name}).');
      }
    }
    for (final product in products) {
      if (reservedStock(product.id) > product.stock) issues.add('${product.name}: açık sipariş rezervasyonu stoktan fazla.');
    }
    final ingredientIds = ingredients.map((item) => item.id).toSet();
    if (ingredientIds.length != ingredients.length) issues.add('Malzeme kimlikleri tekrar ediyor.');
    for (final ingredient in ingredients) {
      if (ingredient.stock < 0 || ingredient.costPerUnit < 0) issues.add('${ingredient.name}: stok veya maliyet negatif.');
      if (reservedIngredientStock(ingredient.id) > ingredient.stock) issues.add('${ingredient.name}: açık siparişlerde ayrılan miktar stoktan fazla.');
    }
    for (final entry in recipes.entries) {
      if (!productIds.contains(entry.key)) issues.add('Reçete bağlı olduğu ürünü bulamıyor: ${entry.key}.');
      for (final line in entry.value) {
        if (!ingredientIds.contains(line.ingredientId) || line.quantity <= 0) {
          issues.add('Ürün reçetesinde eksik malzeme veya geçersiz miktar var.');
        }
      }
    }
    if (registerSessions.where((session) => session.isOpen).length > 1) {
      issues.add('Birden fazla açık kasa vardiyası var.');
    }
    final sessionIds = registerSessions.map((session) => session.id).toSet();
    for(final refund in sales.where((sale)=>sale.isRefund)){final index=refund.refundOfSaleIndex;if(index==null||index<0||index>=sales.length||sales[index].isRefund)issues.add('Satış iadesinin kaynak satışı bulunamıyor.');}
    for(var i=0;i<sales.length;i++){if(!sales[i].isRefund&&refundedAmountForSale(i)>sales[i].total)issues.add('Satış #${i+1}: iade tutarı satış toplamını aşıyor.');}
    for (final movement in cashMovements) {
      if (!sessionIds.contains(movement.sessionId)) issues.add('Nakit hareketi bağlı olduğu vardiyayı bulamıyor.');
      if (movement.amount <= 0) issues.add('Nakit hareketinde geçersiz tutar var.');
    }
    for (final sale in sales) {
      if ((sale.total < 0 && !sale.isRefund) || (sale.total >= 0 && sale.isRefund) || sale.items.any((item) => item.qty <= 0 || item.unitCost < 0)) {
        issues.add('${sale.date} tarihli satışta geçersiz tutar veya ürün miktarı var.');
      }
      if (sale.payments.fold<int>(0, (sum, part) => sum + part.amount) != sale.total) {
        issues.add('${sale.date} tarihli satışın ödeme toplamı satış tutarıyla eşleşmiyor.');
      }
      if (sale.registerSessionId != null && !sessionIds.contains(sale.registerSessionId)) {
        issues.add('${sale.date} tarihli satışın kasa vardiyası bulunamıyor.');
      }
    }
    final supplierIds = suppliers.map((item) => item.id).toSet();
    if (supplierIds.length != suppliers.length) issues.add('Tedarikçi kimlikleri yineleniyor.');
    for (final purchase in purchases) {
      if (!supplierIds.contains(purchase.supplierId) || !productIds.contains(purchase.productId) ||
          purchase.quantity <= 0 || purchase.unitCost < 0) issues.add('Geçersiz veya bağlantısı kopuk mal alımı kaydı.');
    }
    final reservationIds = reservations.map((item) => item.id).toSet();
    if (reservationIds.length != reservations.length) issues.add('Rezervasyon kimlikleri yineleniyor.');
    for (final reservation in reservations) {
      if (reservation.guests < 1 || reservation.tableId < 1 || reservation.tableId > kTableCount ||
          DateTime.tryParse(reservation.dateTime) == null) issues.add('Geçersiz masa rezervasyonu kaydı.');
    }
    if (productBarcodes.values.toSet().length != productBarcodes.length) issues.add('Bir barkod birden fazla ürüne atanmış.');
    for (final entry in productBarcodes.entries) {
      if (!productIds.contains(entry.key) || entry.value.trim().isEmpty) issues.add('Barkod eşleşmesi olmayan ürün kaydı var.');
    }
    try {
      final files = await listBackups();
      for (final file in files) {
        if (!isRestorableBackupFileName(file.name)) continue;
        final payload = await readBackup(file.name);
        if (payload == null) { issues.add('Yedek okunamıyor: ${file.name}.'); continue; }
        final decoded = jsonDecode(payload);
        if (decoded is! Map || decoded['products'] is! List ||
            decoded['tables'] is! List || decoded['sales'] is! List) {
          issues.add('Yedek dosyası bozuk: ${file.name}.');
        }
      }
    } catch (_) {
      issues.add('Yedek dosyaları denetlenemedi.');
    }
    return issues;
  }

  Future<void> flush()=>_queue;
  void save() {
    if (recoveryRequired) return;
    final snapshot = jsonEncode({
      'timestampFormatVersion': 2,
      'products': products.map((e) => e.toJson()).toList(),
      'tables': tables.map((e) => e.toJson()).toList(),
      'sales': sales.map((e) => e.toJson()).toList(),
      'expenses': expenses.map((e) => e.toJson()).toList(),
      'stockMovements': stockMovements.map((e) => e.toJson()).toList(),
      'ingredients': ingredients.map((e) => e.toJson()).toList(),
      'recipes': recipes.map((key, value) => MapEntry(key, value.map((e) => e.toJson()).toList())),
      'registerSessions': registerSessions.map((e) => e.toJson()).toList(),
      'cashMovements': cashMovements.map((e) => e.toJson()).toList(),
      'staff': staff.map((e) => e.toJson()).toList(),
      'pinSecurity': pinSecurity,
      'audit': audit.map((e) => e.toJson()).toList(),
      'kitchenNotices': kitchenNotices.map((e) => e.toJson()).toList(),
      'currentUser': currentUser,
      'advanced': {'suppliers': suppliers.map((e)=>e.toJson()).toList(), 'purchases': purchases.map((e)=>e.toJson()).toList(), 'customers': customers.map((e)=>e.toJson()).toList(), 'reservations': reservations.map((e)=>e.toJson()).toList(), 'barcodes': productBarcodes},
    });
    _queue = _queue.catchError((Object _) {}).then((_) async {
      try {
        await _repository.write(snapshot);
      } catch (error) {
        appMessengerKey.currentState?.showSnackBar(SnackBar(
          content: Text('Veriler kaydedilemedi. Depolama alanını kontrol edin. ($error)'),
          duration: const Duration(seconds: 6),
        ));
      }
    });
    notifyListeners();
  }
  void log(String action,String detail){audit.insert(0,Audit(stamp(azWallTime(azNow())),currentUser,action,detail)); if(audit.length>2000)audit.removeRange(2000,audit.length);}
  Staff? get _activeStaff {
    for (final member in staff) {
      if (member.name == currentUser && member.active) return member;
    }
    return null;
  }
  bool get isWaiter => _activeStaff?.role == 'Garson';
  bool get isCashier => _activeStaff?.role == 'Kasiyer';
  bool get isKitchenStaff => _activeStaff?.role == 'Mutfak';
  bool get isAdmin => currentUser == 'Admin' && staff.any((member) => member.name == 'Admin' && member.active);
  void lockSession({String reason = 'Oturum kilitlendi'}) {
    if (currentUser.isEmpty) return;
    final previousUser = currentUser;
    log(reason, '$previousUser oturumu kapatıldı');
    currentUser = '';
    save();
  }
  int pinLockRemainingSeconds(String scope) {
    final state=pinSecurity[scope]; final raw=state?['lockedUntil']?.toString();
    if(raw==null)return 0; final until=DateTime.tryParse(raw)?.toUtc();
    if(until==null)return 0; final seconds=until.difference(DateTime.now().toUtc()).inSeconds;
    return seconds>0?seconds+1:0;
  }
  int pinLockRemainingForStaff(Staff member)=>pinLockRemainingSeconds('staff:${member.name}');
  void _recordPinFailure(String scope) {
    final state=Map<String,dynamic>.from(pinSecurity[scope]??const {});
    final attempts=((state['failedAttempts'] as num?)?.toInt()??0)+1;
    final lockouts=(state['lockouts'] as num?)?.toInt()??0;
    if(attempts>=5){
      final nextLockouts=lockouts+1; final seconds=nextLockouts==1?30:nextLockouts==2?60:300;
      state['failedAttempts']=0;state['lockouts']=nextLockouts;
      state['lockedUntil']=DateTime.now().toUtc().add(Duration(seconds:seconds)).toIso8601String();
      log('Güvenlik','PIN denemeleri nedeniyle $scope kilitlendi: $seconds saniye');
    }else{
      state['failedAttempts']=attempts;state['lockouts']=lockouts;
      log('Güvenlik','Başarısız PIN denemesi ($attempts/5) · $scope');
    }
    pinSecurity[scope]=state;
  }
  bool _verifyPinAttempt(List<Staff> candidates,String candidate) {
    final eligible=candidates.where((member)=>member.active&&member.pinRequired&&pinLockRemainingSeconds('staff:${member.name}')==0).toList();
    if(eligible.isEmpty)return false;
    Staff? matched;
    for(final member in eligible){if(member.verifyPin(candidate)){matched=member;break;}}
    if(matched!=null){pinSecurity.remove('staff:${matched.name}');log('Güvenlik','${matched.name} için PIN doğrulaması başarılı');save();return true;}
    for(final member in eligible){_recordPinFailure('staff:${member.name}');}
    save();return false;
  }
  bool verifyStaffPin(Staff member,String pin)=>staff.contains(member)&&member.pinRequired&&_verifyPinAttempt([member],pin);
  bool verifyAdminPin(String pin) {
    final admins=staff.where((member)=>member.name=='Admin'&&member.active).toList();
    return _verifyPinAttempt(admins,pin);
  }
  bool verifySupervisorPin(String pin) {
    final supervisors=staff.where((member)=>member.active&&(member.name=='Admin'||member.role=='Kasiyer')).toList();
    return _verifyPinAttempt(supervisors,pin);
  }
  bool can(String permission) {
    if (isAdmin) return true;
    if (isWaiter) return permission == 'orders';
    if (isCashier) return permission == 'orders' || permission == 'register';
    if (isKitchenStaff) return permission == 'kitchen';
    return false;
  }
  bool loginAsStaff(Staff member, {String? pin}) {
    if (!staff.contains(member) || !member.active ||
        !['Garson', 'Kasiyer', 'Mutfak'].contains(member.role)) return false;
    if (member.role == 'Garson') {
      if (member.pinRequired) return false;
    } else if (!member.pinRequired || pin == null || !verifyStaffPin(member,pin)) {
      return false;
    }
    currentUser = member.name;
    log('Giriş', '${member.role} oturumu açıldı');
    save();
    notifyListeners();
    return true;
  }
  bool loginAsWaiter(Staff member) => member.role == 'Garson' && loginAsStaff(member);
  int get todayTotal=>sales.where((s)=>s.date==dayKey(azWallTime(azNow()))).fold(0,(a,s)=>a+s.total); int get todayCount=>sales.where((s)=>s.date==dayKey(azWallTime(azNow()))).length;
  int reservedStock(String productId) => tables.fold(0, (sum, table) =>
      sum + table.items.where((line) => line.productId == productId).fold(0, (n, line) => n + line.qty));
  int reservedIngredientStock(String ingredientId) {
    var reserved = 0;
    for (final table in tables) {
      for (final line in table.items) {
        final recipe = recipes[line.productId] ?? const <RecipeLine>[];
        for (final item in recipe.where((entry) => entry.ingredientId == ingredientId)) {
          reserved += item.quantity * line.qty;
        }
      }
    }
    return reserved;
  }
  int recipeCost(Product product) {
    return (recipes[product.id] ?? const <RecipeLine>[]).fold(0, (sum, item) {
      final ingredient = ingredients.where((entry) => entry.id == item.ingredientId);
      return sum + (ingredient.isEmpty ? 0 : ingredient.first.costPerUnit * item.quantity);
    });
  }
  bool recipeAvailable(Product product, {int extra = 1}) {
    for (final item in recipes[product.id] ?? const <RecipeLine>[]) {
      final ingredient = ingredients.where((entry) => entry.id == item.ingredientId);
      if (ingredient.isEmpty ||
          ingredient.first.stock - reservedIngredientStock(item.ingredientId) < item.quantity * extra) return false;
    }
    return true;
  }
  bool addIngredient(Ingredient ingredient) {
    if (!can('inventory') || ingredient.name.trim().isEmpty || ingredient.unit.trim().isEmpty ||
        ingredient.stock < 0 || ingredient.costPerUnit < 0 ||
        ingredients.any((item) => item.id == ingredient.id)) return false;
    ingredients.add(ingredient);
    log('Malzeme', '${ingredient.name} oluşturuldu');
    save();
    return true;
  }
  bool adjustIngredient(Ingredient ingredient, int delta) {
    if (!can('inventory') || !ingredients.contains(ingredient) || delta == 0 ||
        ingredient.stock + delta < reservedIngredientStock(ingredient.id)) return false;
    ingredient.stock += delta;
    log('Malzeme stoku', '${ingredient.name}: ${ingredient.stock} ${ingredient.unit}');
    save();
    return true;
  }
  bool setRecipe(Product product, List<RecipeLine> lines) {
    if (!can('inventory') || !products.contains(product) ||
        lines.any((line) => line.quantity <= 0 ||
          !ingredients.any((item) => item.id == line.ingredientId)) ||
        lines.map((line) => line.ingredientId).toSet().length != lines.length) return false;
    recipes[product.id] = List<RecipeLine>.from(lines);
    log('Reçete', '${product.name}: ${lines.length} malzeme tanımlandı');
    save();
    return true;
  }


  bool addSupplier(SupplierRecord supplier) {
    if (!can('inventory') || supplier.name.trim().isEmpty ||
        suppliers.any((item) => item.name.toLowerCase() == supplier.name.trim().toLowerCase())) return false;
    suppliers.add(supplier); log('Tedarikçi', '${supplier.name} eklendi'); save(); return true;
  }
  bool recordPurchase({required String supplierId, required String productId, required int quantity, required int unitCost}) {
    if (!can('inventory') || quantity <= 0 || unitCost < 0) return false;
    final supplier = suppliers.where((item) => item.id == supplierId && item.active);
    final product = products.where((item) => item.id == productId);
    if (supplier.isEmpty || product.isEmpty) return false;
    final item = product.first;
    if (item.stock + quantity > 100000000) return false;
    final beforeStock = item.stock;
    final previousValue = beforeStock * item.costPrice;
    final nextStock = beforeStock + quantity;
    // Integer-only weighted average avoids floating-point drift in qəpik values.
    item.costPrice = ((previousValue + quantity * unitCost + nextStock ~/ 2) ~/ nextStock);
    item.stock = nextStock;
    final now = azNow();
    final movementId = now.microsecondsSinceEpoch;
    purchases.add(PurchaseRecord(id: movementId.toString(),
      supplierId: supplier.first.id, supplierName: supplier.first.name, productId: item.id,
      productName: item.name, quantity: quantity, unitCost: unitCost, at: now.toIso8601String()));
    stockMovements.add(StockMovement(id: movementId, productId: item.id,
      productName: item.name, type: 'Alım', quantity: quantity,
      beforeStock: beforeStock, afterStock: nextStock, productCost: unitCost,
      at: now.toIso8601String(), note: 'Mal alımı · ${supplier.first.name}'));
    log('Mal alımı', '${supplier.first.name}: ${item.name} × $quantity'); save(); return true;
  }
  bool addCustomer(CustomerRecord customer) {
    if (!can('reports') || customer.name.trim().isEmpty ||
        customers.any((item) => item.phone.isNotEmpty && item.phone == customer.phone && customer.phone.isNotEmpty)) return false;
    customers.add(customer); log('Müşteri', '${customer.name} kaydedildi'); save(); return true;
  }
  bool addReservation(ReservationRecord reservation) {
    if (!can('reports') || reservation.customerName.trim().isEmpty || reservation.guests < 1 ||
        reservation.tableId < 1 || reservation.tableId > kTableCount) return false;
    final when = DateTime.tryParse(reservation.dateTime);
    if (when == null || when.isBefore(azNow().subtract(const Duration(minutes: 5)))) return false;
    final overlaps = reservations.any((item) {
      if (item.tableId != reservation.tableId || item.status == 'İptal' || item.status == 'Tamamlandı') return false;
      final existing = DateTime.tryParse(item.dateTime);
      return existing != null && existing.difference(when).inMinutes.abs() < 120;
    });
    if (overlaps) return false;
    reservations.add(reservation); log('Rezervasyon', 'Masa ${reservation.tableId}: ${reservation.customerName}'); save(); return true;
  }
  bool setReservationStatus(ReservationRecord reservation, String status) {
    if (!can('reports') || !reservations.contains(reservation) ||
        !['Bekliyor','Geldi','Tamamlandı','İptal'].contains(status)) return false;
    reservation.status = status; log('Rezervasyon', '${reservation.customerName}: $status'); save(); return true;
  }
  bool setProductBarcode(Product product, String barcode) {
    if (!can('inventory') || !products.contains(product)) return false;
    final value = barcode.trim();
    if (value.isNotEmpty && productBarcodes.entries.any((entry) => entry.key != product.id && entry.value == value)) return false;
    if (value.isEmpty) { productBarcodes.remove(product.id); } else { productBarcodes[product.id] = value; }
    log('Barkod', '${product.name}: ${value.isEmpty ? 'kaldırıldı' : value}'); save(); return true;
  }
  Product? productByBarcode(String barcode) {
    final value = barcode.trim();
    if (value.isEmpty) return null;
    final match = productBarcodes.entries.where((entry) => entry.value == value);
    if (match.isEmpty) return null;
    final found = products.where((item) => item.id == match.first.key && item.active);
    return found.isEmpty ? null : found.first;
  }

  bool add(PosTable t, Product p) {
    if (!can('orders') || !p.active || reservedStock(p.id) >= p.stock || !recipeAvailable(p)) return false;
    final existing = t.items.where((line) => line.productId == p.id && !line.sent);
    if (existing.isNotEmpty) { existing.first.qty++; } else { t.items.add(OrderLine(p.id, p.name, p.price, 1)); }
    log('Sipariş', 'Masa ${t.id}: ${p.name} eklendi'); save(); return true;
  }
  bool qty(PosTable t, int i, int delta) {
    if (!can('orders') || i < 0 || i >= t.items.length) return false;
    final line = t.items[i]; if (line.sent && delta < 0) return false; final product = products.where((p) => p.id == line.productId);
    if (delta > 0 && (product.isEmpty || reservedStock(line.productId) >= product.first.stock || !recipeAvailable(product.first))) return false;
    if (delta > 0 && line.sent) {
      final pending = t.items.where((item) => item.productId == line.productId && !item.sent);
      if (pending.isNotEmpty) { pending.last.qty++; }
      else { t.items.add(OrderLine(line.productId, line.name, line.price, 1)); }
    } else { line.qty += delta; if (line.qty <= 0) t.items.removeAt(i); }
    if (t.items.isEmpty) { t.discount=0; t.discountPercent=false; t.discountReason=''; t.kitchen=KitchenState.queued; }
    else if (t.discountPercent ? t.discount > 99 : t.discount >= t.subtotal) { t.discount=0; t.discountPercent=false; t.discountReason=''; log('İndirim sıfırlandı','Masa ${t.id}: ara toplam değiştiği için indirim kaldırıldı'); }
    log('Sipariş', 'Masa ${t.id}: miktar değişti'); save(); return true;
  }
  bool sendKitchen(PosTable t) {
    if (!can('orders') || !t.items.any((line) => !line.sent)) return false;
    for (final line in t.items.where((line) => !line.sent)) {
      line.sent = true;
      line.kitchen = KitchenState.queued;
    }
    t.kitchen = KitchenState.queued;
    log('Mutfak', 'Masa ${t.id}: yeni ürünler mutfağa gönderildi');
    save();
    return true;
  }
  bool cancelSentLine(PosTable table, OrderLine line, int quantity, String reason, String supervisorPin) {
    if (!can('orders') || !table.items.contains(line) || !line.sent || quantity <= 0 ||
        quantity > line.qty || reason.trim().isEmpty || !verifySupervisorPin(supervisorPin)) return false;
    final cancelledName = line.name;
    if (quantity == line.qty) { table.items.remove(line); } else { line.qty -= quantity; }
    if (table.items.isEmpty) { table.discount=0; table.discountPercent=false; table.discountReason=''; table.kitchen=KitchenState.queued; }
    else if (table.discountPercent ? table.discount > 99 : table.discount >= table.subtotal) { table.discount=0; table.discountPercent=false; table.discountReason=''; log('İndirim sıfırlandı','Masa ${table.id}: iptal sonrası ara toplam değiştiği için indirim kaldırıldı'); }
    kitchenNotices.insert(0, KitchenNotice(id:DateTime.now().microsecondsSinceEpoch,tableId:table.id,quantity:quantity,at:azNow().toIso8601String(),productName:cancelledName,reason:reason.trim(),by:currentUser));
    log('Gönderilmiş ürün iptali', 'Masa ${table.id}: $cancelledName × $quantity · Neden: ${reason.trim()}');
    save();
    return true;
  }
  bool acknowledgeKitchenNotice(KitchenNotice notice) {
    if (!can('kitchen') || !kitchenNotices.contains(notice) || notice.acknowledged) return false;
    notice.acknowledged=true; log('Mutfak bildirimi', 'Masa ${notice.tableId}: iptal bildirimi görüldü'); save(); return true;
  }
  bool setKitchenLine(PosTable table, OrderLine line, KitchenState state) {
    if (!can('kitchen') || !line.sent || line.kitchen == KitchenState.served ||
        !table.items.contains(line)) return false;
    line.kitchen = state;
    table.kitchen = tableKitchenState(table);
    log('Mutfak', 'Masa ${table.id}: ${line.name} → ${state.name}');
    save();
    return true;
  }
  bool moveTable(PosTable source, PosTable destination) {
    if (!can('table_manage') || source == destination || source.items.isEmpty ||
        destination.items.isNotEmpty) return false;
    destination.items.addAll(source.items);
    destination.discount = source.discount;
    destination.discountPercent = source.discountPercent;
    destination.discountReason = source.discountReason;
    destination.kitchen = tableKitchenState(destination);
    source.items.clear();
    source.discount = 0; source.discountPercent = false; source.discountReason = '';
    source.kitchen = KitchenState.queued;
    log('Masa taşıma', 'Masa ${source.id} → Masa ${destination.id}');
    save();
    return true;
  }

  bool mergeTables(PosTable source, PosTable destination) {
    if (!can('table_manage') || source == destination || source.items.isEmpty ||
        destination.items.isEmpty) return false;
    int discountOf(PosTable table) => table.discountPercent
        ? table.subtotal * table.discount ~/ 100 : table.discount;
    final combinedSubtotal = source.subtotal + destination.subtotal;
    final combinedDiscount = discountOf(source) + discountOf(destination);
    if (combinedDiscount >= combinedSubtotal) return false;
    destination.items.addAll(source.items);
    destination.discount = combinedDiscount;
    destination.discountPercent = false;
    destination.discountReason = [destination.discountReason, source.discountReason]
        .where((reason) => reason.trim().isNotEmpty).join(' + ');
    destination.kitchen = tableKitchenState(destination);
    source.items.clear();
    source.discount = 0; source.discountPercent = false; source.discountReason = '';
    source.kitchen = KitchenState.queued;
    log('Masa birleştirme', 'Masa ${source.id} → Masa ${destination.id}');
    save();
    return true;
  }

  bool splitTable(PosTable source, PosTable destination,
      {required int lineIndex, required int quantity}) {
    if (!can('table_manage') || source == destination || source.items.isEmpty ||
        destination.items.isNotEmpty || source.discount != 0 ||
        destination.discount != 0 || lineIndex < 0 ||
        lineIndex >= source.items.length) return false;
    final line = source.items[lineIndex];
    if (quantity <= 0 || quantity > line.qty) return false;
    destination.items.add(OrderLine(line.productId, line.name, line.price, quantity,
        sent: line.sent, kitchen: line.kitchen, unitCost: line.unitCost));
    line.qty -= quantity;
    if (line.qty == 0) source.items.removeAt(lineIndex);
    destination.kitchen = tableKitchenState(destination);
    source.kitchen = tableKitchenState(source);
    log('Masa bölme', 'Masa ${source.id} → Masa ${destination.id}: ${line.name} × $quantity');
    save();
    return true;
  }

  void setKitchen(PosTable t, KitchenState state) {
    if (!can('kitchen') || !t.items.any((line) => line.sent && line.kitchen != KitchenState.served)) return;
    for (final line in t.items.where((line) => line.sent && line.kitchen != KitchenState.served)) {
      line.kitchen = state;
    }
    t.kitchen = state;
    log('Mutfak', 'Masa ${t.id}: ${state.name}');
    save();
  }
  bool clearDiscount(PosTable t) { if (!can('discount') || t.discount==0) return false; t.discount=0; t.discountPercent=false; t.discountReason=''; log('İndirim kaldırıldı', 'Masa ${t.id}'); save(); return true; }
  bool setDiscount(PosTable t, int value, bool percent, String reason) {
    if (!can('discount') || t.items.isEmpty || reason.trim().isEmpty || value <= 0) return false;
    if (percent ? value > 99 : value >= t.subtotal) return false;
    t.discount = value; t.discountPercent = percent; t.discountReason = reason.trim();
    log('İndirim', 'Masa ${t.id}: ${percent ? '%$value' : money(value)} · ${reason.trim()}'); save(); return true;
  }
  void upsertProduct(Product p) {
    if (!can('inventory') || p.stock < reservedStock(p.id)) return;
    final i = products.indexWhere((e) => e.id == p.id); if (i < 0) products.add(p); else { p.active=products[i].active; products[i] = p; }
    log('Menü', '${p.name} kaydedildi'); save();
  }
  bool stockChange(Product p, int delta, {String note='Manuel stok düzeltmesi'}) {
    if (!can('inventory') || !products.contains(p) || delta == 0 || note.trim().isEmpty) return false;
    final before = p.stock;
    final next = (before + delta).clamp(0, 1000000).toInt();
    final actualDelta = next - before;
    if (next < reservedStock(p.id) || actualDelta == 0) return false;
    p.stock = next;
    stockMovements.add(StockMovement(
      id: DateTime.now().microsecondsSinceEpoch,
      productId: p.id,
      productName: p.name,
      type: actualDelta > 0 ? 'Giriş' : 'Çıkış',
      quantity: actualDelta.abs(),
      beforeStock: before,
      afterStock: next,
      productCost: p.costPrice,
      at: azNow().toIso8601String(),
      note: note.trim(),
    ));
    log('Stok', '${p.name}: $before → $next · ${note.trim()}');
    save();
    return true;
  }
  bool addExpense(int amount,String category,String note){if(!can('reports')||amount<=0||category.trim().isEmpty||note.trim().isEmpty)return false;expenses.add(Expense(id:DateTime.now().microsecondsSinceEpoch,amount:amount,category:category.trim(),note:note.trim(),date:dayKey(azWallTime(azNow()))));log('Gider','${category.trim()} · ${money(amount)} · ${note.trim()}');save();return true;}
  int costOfSale(Sale sale)=>sale.items.fold(0,(s,item)=>s+item.unitCost*item.qty) * (sale.isRefund ? -1 : 1);
  int refundedAmountForSale(int saleIndex) => sales.where((sale)=>sale.isRefund&&sale.refundOfSaleIndex==saleIndex).fold<int>(0,(sum,sale)=>sum-sale.total);
  int remainingRefundable(int saleIndex) { if(saleIndex<0||saleIndex>=sales.length||sales[saleIndex].isRefund)return 0; return (sales[saleIndex].total-refundedAmountForSale(saleIndex)).clamp(0,1<<30).toInt(); }
  bool refundSale(int saleIndex,int amount,String reason,String adminPin,{bool returnStock=false}) {
    if(!isAdmin||!verifyAdminPin(adminPin)||activeRegister==null||saleIndex<0||saleIndex>=sales.length||amount<=0||reason.trim().isEmpty)return false;
    final original=sales[saleIndex]; final remaining=remainingRefundable(saleIndex);
    if(original.isRefund||amount>remaining||(returnStock&&(amount!=remaining||original.stockReturned)))return false;
    final productNeeds=<String,int>{}; final ingredientNeeds=<String,int>{};
    if(returnStock){for(final line in original.items){productNeeds[line.productId]=(productNeeds[line.productId]??0)+line.qty;}
      if(original.ingredientUsage!=null){ingredientNeeds.addAll(original.ingredientUsage!);}else{for(final line in original.items){for(final recipeLine in recipes[line.productId]??const <RecipeLine>[]){ingredientNeeds[recipeLine.ingredientId]=(ingredientNeeds[recipeLine.ingredientId]??0)+recipeLine.quantity*line.qty;}}}
      for(final entry in productNeeds.entries){final p=products.where((item)=>item.id==entry.key);if(p.isEmpty||p.first.stock+entry.value>100000000)return false;}
      for(final entry in ingredientNeeds.entries){final item=ingredients.where((x)=>x.id==entry.key);if(item.isEmpty||item.first.stock+entry.value>100000000)return false;}
    }
    final now=azNow(); final session=activeRegister!;
    if(expectedRegisterCash(session)<amount)return false;
    cashMovements.add(CashMovement(id:DateTime.now().microsecondsSinceEpoch,sessionId:session.id,at:now.toIso8601String(),type:'Çıxış',amount:amount,note:'Satış iadesi · Masa ${original.table} · ${reason.trim()}'));
    if(returnStock){for(final entry in productNeeds.entries){final product=products.firstWhere((item)=>item.id==entry.key);final before=product.stock;product.stock+=entry.value;stockMovements.add(StockMovement(id:DateTime.now().microsecondsSinceEpoch,productId:product.id,productName:product.name,type:'İade',quantity:entry.value,beforeStock:before,afterStock:product.stock,productCost:product.costPrice,at:now.toIso8601String(),note:'Satış iadesi · Masa ${original.table}'));}
      for(final entry in ingredientNeeds.entries){ingredients.firstWhere((item)=>item.id==entry.key).stock+=entry.value;} original.stockReturned=true;}
    sales.add(Sale(dayKey(azWallTime(now)),stamp(azWallTime(now)),currentUser,original.table,-amount,0,returnStock?original.items.map((item)=>OrderLine(item.productId,item.name,item.price,item.qty,unitCost:item.unitCost)).toList():<OrderLine>[],[PaymentPart('İade',-amount,tendered:-amount)],registerSessionId:session.id,isRefund:true,refundOfSaleIndex:saleIndex,reason:reason.trim()));
    log('Satış iadesi','Satış #${saleIndex+1}: ${money(amount)} · ${reason.trim()}${returnStock?' · Stok geri alındı':''}'); save(); return true;
  }int get totalExpenses=>expenses.fold(0,(s,e)=>s+e.amount);int get totalCostOfSales=>sales.fold(0,(s,e)=>s+costOfSale(e));int get netProfit=>sales.fold(0,(s,e)=>s+e.total-costOfSale(e))-totalExpenses;
  String buildCsv(){String q(Object? v)=>'"${v.toString().replaceAll('"','""')}"';final b=StringBuffer('Tarih;Tür;Açıklama;Adet;Ciro/Gider;Maliyet\r\n');for(final sale in sales){b.writeln([q(sale.date),q('Satış'),q('Masa ${sale.table}'),q(sale.items.fold<int>(0,(int n,OrderLine x)=>n+x.qty)),q(sale.total/100),q(costOfSale(sale)/100)].join(';'));}for(final e in expenses){b.writeln([q(e.date),q('Gider'),q('${e.category}: ${e.note}'),q(1),q(e.amount/100),q(0)].join(';'));}return b.toString();}
  bool checkout(PosTable t, List<PaymentPart> payments, {String? staffName}) {
    if (!can('register') || t.items.isEmpty || t.items.any((line) => !line.sent)) return false;
    final total = t.total;
    if (payments.isEmpty || payments.any((part) => !part.isValid) || payments.fold(0, (sum, part) => sum + part.amount) != total) return false;
    final register = activeRegister;
    final hasCashPayment = payments.any((part) => part.method == 'Nakit');
    if (hasCashPayment && register == null) return false;
    final seller = (staffName ?? currentUser).trim();
    if (seller.isEmpty) return false;

    final productNeeds = <String, int>{};
    final ingredientNeeds = <String, int>{};
    for (final line in t.items) {
      productNeeds[line.productId] =
          (productNeeds[line.productId] ?? 0) + line.qty;
      for (final recipeLine in recipes[line.productId] ?? const <RecipeLine>[]) {
        ingredientNeeds[recipeLine.ingredientId] =
            (ingredientNeeds[recipeLine.ingredientId] ?? 0) + recipeLine.quantity * line.qty;
      }
    }
    for (final entry in productNeeds.entries) {
      final product = products.where((item) => item.id == entry.key);
      if (product.isEmpty || product.first.stock < entry.value) return false;
    }
    for (final entry in ingredientNeeds.entries) {
      final ingredient = ingredients.where((item) => item.id == entry.key);
      if (ingredient.isEmpty || ingredient.first.stock < entry.value) return false;
    }

    final now = azNow();
    for (final entry in productNeeds.entries) {
      final product = products.firstWhere((item) => item.id == entry.key);
      final before = product.stock;
      product.stock -= entry.value;
      stockMovements.add(StockMovement(id: DateTime.now().microsecondsSinceEpoch,
        productId: product.id, productName: product.name, type: 'Satış',
        quantity: entry.value, beforeStock: before, afterStock: product.stock,
        productCost: product.costPrice, at: now.toIso8601String(),
        note: 'Masa ${t.id} satışı'));
    }
    for (final entry in ingredientNeeds.entries) {
      final ingredient = ingredients.firstWhere((item) => item.id == entry.key);
      ingredient.stock -= entry.value;
    }
    sales.add(Sale(dayKey(azWallTime(now)), stamp(azWallTime(now)), seller, t.id, total, t.subtotal-total,
      t.items.map((e) { final product=products.firstWhere((p)=>p.id==e.productId); return OrderLine(e.productId,e.name,e.price,e.qty,unitCost:product.costPrice + recipeCost(product)); }).toList(), payments,
      registerSessionId: register?.id, ingredientUsage: Map<String,int>.from(ingredientNeeds), discountReason: t.discountReason, discountPercent: t.discountPercent));
    log('Ödeme', 'Masa ${t.id}: ${money(total)}');
    t.items = []; t.discount = 0; t.discountPercent = false; t.discountReason = ''; t.kitchen = KitchenState.queued;
    save(); return true;
  }
  RegisterSession? get activeRegister {
    for (final session in registerSessions.reversed) {
      if (session.isOpen) return session;
    }
    return null;
  }
  int cashSalesForSession(int sessionId) => sales
      .where((sale) => sale.registerSessionId == sessionId)
      .fold(0, (sum, sale) => sum + sale.payments
          .where((part) => part.method == 'Nakit')
          .fold(0, (value, part) => value + part.amount));
  int cashMovementsForSession(int sessionId) => cashMovements
      .where((movement) => movement.sessionId == sessionId)
      .fold(0, (sum, movement) => sum +
          (movement.type == 'Giriş' ? movement.amount : -movement.amount));
  int expectedRegisterCash(RegisterSession session) =>
      session.openingCash + cashSalesForSession(session.id) +
      cashMovementsForSession(session.id);
  bool openRegister(int openingCash, {String note = ''}) {
    if (!can('register') || activeRegister != null || openingCash < 0) return false;
    final now = azNow();
    registerSessions.add(RegisterSession(
      id: now.microsecondsSinceEpoch,
      openedAt: now.toIso8601String(),
      openingCash: openingCash,
      note: note.trim(),
    ));
    log('Kasa açıldı', 'Açılış nakdi: ${money(openingCash)}');
    save();
    return true;
  }
  bool addCashMovement(String type, int amount, String note) {
    final session = activeRegister;
    if (!can('register') || session == null ||
        (type != 'Giriş' && type != 'Çıxış') || amount <= 0 ||
        note.trim().isEmpty) return false;
    if (type == 'Çıxış' && expectedRegisterCash(session) < amount) return false;
    cashMovements.add(CashMovement(
      id: DateTime.now().microsecondsSinceEpoch,
      sessionId: session.id,
      at: azNow().toIso8601String(),
      type: type,
      amount: amount,
      note: note.trim(),
    ));
    log(type == 'Giriş' ? 'Kasaya nakit girişi' : 'Kasadan nakit çıkışı',
      '${money(amount)} · ${note.trim()}');
    save();
    return true;
  }
  bool closeRegister(int countedCash, {String note = ''}) {
    final session = activeRegister;
    if (!can('register') || session == null || countedCash < 0) return false;
    session.expectedCash = expectedRegisterCash(session);
    session.closingCash = countedCash;
    session.closedAt = azNow().toIso8601String();
    if (note.trim().isNotEmpty) session.note = note.trim();
    final difference = countedCash - session.expectedCash!;
    log('Kasa bağlandı', 'Beklenen: ${money(session.expectedCash!)} · Sayılan: ${money(countedCash)} · Fark: ${money(difference)}');
    save();
    return true;
  }
  bool addStaff(String name,String role,String? pin) {
    final clean=name.trim();
    final requiresPin=role!='Garson';
    final validPin=pin!=null && pin.length==4 && int.tryParse(pin)!=null && pin!='1234';
    if(!can('staff')||clean.isEmpty||clean.toLowerCase()=='admin'||
      staff.any((x)=>x.name.toLowerCase()==clean.toLowerCase())||
      !['Garson','Kasiyer','Mutfak'].contains(role)||
      (requiresPin&&!validPin)) return false;
    staff.add(Staff(clean,role,pin:pin??'1234',pinRequired:requiresPin));
    log('Personel','Personel eklendi: $clean ($role)'); save(); return true;
  }
  bool setStaffActive(Staff member,bool active) { if(!can('staff')||member.name=='Admin')return false; member.active=active; log('Personel','${member.name}: ${active?'aktif':'pasif'}'); save(); return true; }
  int get lowStock=>products.where((p)=>p.active&&p.stock<=p.lowAt).length;
}
final pos=Pos();
Future<void> main() async {WidgetsFlutterBinding.ensureInitialized();await pos.load();runApp(const PosApp());}
class PosLogo extends StatelessWidget { final double size; const PosLogo({super.key, this.size = 112}); @override Widget build(BuildContext context) => Image.asset('assets/branding/restoram_logo.jpg', width: size, height: size, fit: BoxFit.contain); }
class PosApp extends StatelessWidget {const PosApp({super.key});@override Widget build(BuildContext context)=>MaterialApp(scaffoldMessengerKey:appMessengerKey,title:'Restaurant POS',debugShowCheckedModeBanner:false,locale:const Locale('tr','TR'),supportedLocales:const [Locale('tr','TR')],localizationsDelegates: GlobalMaterialLocalizations.delegates,theme:ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:ink),scaffoldBackgroundColor:bg,appBarTheme:const AppBarTheme(backgroundColor:ink,foregroundColor:Colors.white)),home:pos.recoveryRequired ? const RecoveryPage() : const Home());}

class Home extends StatefulWidget {const Home({super.key});@override State<Home> createState()=>_HomeState();}
class _HomeState extends State<Home> with WidgetsBindingObserver {
  int tab=0; bool authenticated=false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      // Lock the UI when the app leaves the foreground; persist pending writes first.
      pos.flush().then((_) {
        if (mounted && authenticated) _logout();
      }).catchError((Object _) {
        if (mounted && authenticated) _logout();
      });
    }
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  void _logout(){
    pos.lockSession(reason: 'Oturum kilitlendi');
    tab=0;
    setState(()=>authenticated=false);
  }
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(context,_){
    if(!authenticated)return PinGate(
      onAuthenticated:()=>setState(()=>authenticated=true),
      onStaffSelected:(_)=>setState(()=>authenticated=true),
    );
    if(pos.isWaiter)return Scaffold(body:SafeArea(child:TablesPage(onLogout:_logout)));
    if(pos.isKitchenStaff)return KitchenPage(onLogout:_logout);
    if(pos.isCashier) {
      final pages=[TablesPage(onLogout:_logout),const RegisterPage()];
      final index=tab.clamp(0,1).toInt();
      return Scaffold(
        body:SafeArea(child:pages[index]),
        bottomNavigationBar:NavigationBar(
          selectedIndex:index,
          onDestinationSelected:(value)=>setState(()=>tab=value),
          destinations:const [
            NavigationDestination(icon:Icon(Icons.table_restaurant),label:'Masalar'),
            NavigationDestination(icon:Icon(Icons.point_of_sale),label:'Kasa'),
          ],
        ),
      );
    }
    final pages=[TablesPage(onLogout:_logout),const KitchenPage(),const InventoryPage(),const ReportsPage(),const AdminPage()];
    final index=tab.clamp(0,pages.length-1).toInt();
    return Scaffold(body:SafeArea(child:pages[index]),bottomNavigationBar:NavigationBar(selectedIndex:index,onDestinationSelected:(v)=>setState(()=>tab=v),destinations:const [NavigationDestination(icon:Icon(Icons.table_restaurant),label:'Masalar'),NavigationDestination(icon:Icon(Icons.soup_kitchen),label:'Mutfak'),NavigationDestination(icon:Icon(Icons.inventory_2),label:'Stok'),NavigationDestination(icon:Icon(Icons.bar_chart),label:'Rapor'),NavigationDestination(icon:Icon(Icons.settings),label:'Yönetim')]));
  });
}

class TablesPage extends StatelessWidget {
  final VoidCallback? onLogout;
  const TablesPage({super.key, this.onLogout});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pos,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Restaurant POS'),
        leading: const Padding(padding: EdgeInsets.all(6), child: PosLogo(size: 40)),
        actions: [Padding(padding: const EdgeInsets.all(12),
          child: Center(child: Text(pos.currentUser))),
          if(onLogout!=null) IconButton(tooltip:'Oturumu kapat',onPressed:onLogout,icon:const Icon(Icons.logout))]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 16, children: [
          Text('Tarih: ${stamp(azWallTime(azNow()))}'),
          if (pos.can('reports')) Text('Bugünkü ciro: ${money(pos.todayTotal)}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
          if(pos.can('inventory')) Text('Düşük stok: ${pos.lowStock}'),
        ])),
        Expanded(child: LayoutBuilder(builder: (c, b) {
          final cols = (b.maxWidth / 155).floor().clamp(2, 8).toInt();
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols, mainAxisSpacing: 10, crossAxisSpacing: 10,
              childAspectRatio: b.maxWidth < 600 ? 1.0 : 0.85),
            itemCount: pos.tables.length,
            itemBuilder: (c, i) {
              final t = pos.tables[i];
              final status = tableKitchenState(t);
              final color = t.items.isEmpty ? green : status == KitchenState.ready
                  ? green : status == KitchenState.preparing ? amber : red;
              return Card(child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.push(c,
                  MaterialPageRoute(builder: (_) => OrderPage(table: t))),
                onLongPress: pos.can('staff') ? () => showDialog<void>(context: c,
                  builder: (_) => TableOperationsDialog(source: t)) : null,
                child: Padding(padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Row(children: [
                        Expanded(child: Text('Masa ${t.id}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17))),
                        if(pos.can('table_manage')) const Icon(Icons.swap_horiz, size: 18, color: Colors.black45),
                      ]),
                      Text(kitchenLabel(t)),
                      Text(money(t.total), style: const TextStyle(
                        fontSize: 19, fontWeight: FontWeight.bold)),
                      Container(height: 5, color: color),
                    ])),
              ));
            },
          );
        })),
      ]),
    ),
  );
}

class TableOperationsDialog extends StatefulWidget {
  final PosTable source;
  const TableOperationsDialog({super.key, required this.source});
  @override
  State<TableOperationsDialog> createState() => _TableOperationsDialogState();
}
class _TableOperationsDialogState extends State<TableOperationsDialog> {
  String mode = 'Taşı';
  int? targetId;
  int? lineIndex;
  final quantity = TextEditingController(text: '1');
  @override
  void dispose() { quantity.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final targets = pos.tables.where((table) => table.id != source.id &&
      (mode == 'Birleştir' ? table.items.isNotEmpty : table.items.isEmpty)).toList();
    if (targetId != null && !targets.any((table) => table.id == targetId)) targetId = null;
    return AlertDialog(
      title: Text('Masa ${source.id} işlemleri'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: mode,
            decoration: const InputDecoration(labelText: 'İşlem'),
            items: const [
              DropdownMenuItem(value: 'Taşı', child: Text('Siparişi başka masaya taşı')),
              DropdownMenuItem(value: 'Birleştir', child: Text('Masaları birleştir')),
              DropdownMenuItem(value: 'Böl', child: Text('Siparişi böl')),
            ],
            onChanged: (value) => setState(() { mode = value ?? 'Taşı'; targetId = null; }),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: targetId,
            decoration: const InputDecoration(labelText: 'Hedef masa'),
            items: targets.map((table) => DropdownMenuItem(
              value: table.id, child: Text('Masa ${table.id}'))).toList(),
            onChanged: (value) => setState(() => targetId = value),
          ),
          if (mode == 'Böl') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: lineIndex,
              decoration: const InputDecoration(labelText: 'Bölünecek ürün'),
              items: [for (var i = 0; i < source.items.length; i++)
                DropdownMenuItem(value: i,
                  child: Text('${source.items[i].name} (×${source.items[i].qty})'))],
              onChanged: (value) => setState(() => lineIndex = value),
            ),
            TextField(controller: quantity, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Hedef masaya aktarılacak adet')),
          ],
          if (mode == 'Böl' && (source.discount > 0))
            const Text('İndirimli masa bölünmeden önce indirim kaldırılmalıdır.',
              style: TextStyle(color: red)),
          if (mode == 'Böl' && source.items.isEmpty)
            const Text('Bölünecek ürün bulunmuyor.'),
        ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('İptal')),
        FilledButton(
          onPressed: targetId == null || source.items.isEmpty ? null : () {
            final target = pos.tables.firstWhere((table) => table.id == targetId);
            final success = switch (mode) {
              'Taşı' => pos.moveTable(source, target),
              'Birleştir' => pos.mergeTables(source, target),
              _ => lineIndex != null && pos.splitTable(source, target,
                lineIndex: lineIndex!, quantity: int.tryParse(quantity.text) ?? 0),
            };
            if (success) Navigator.pop(context);
            else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('İşlem yapılamadı. Masa durumunu ve indirimleri kontrol edin.')));
          },
          child: const Text('Uygula'),
        ),
      ],
    );
  }
}

class OrderPage extends StatefulWidget{final PosTable table;const OrderPage({super.key,required this.table});@override State<OrderPage> createState()=>_OrderPageState();}
class _OrderPageState extends State<OrderPage>{String category='Tümü';PosTable get t=>widget.table;@override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(c,_){final cats=['Tümü',...pos.products.map((p)=>p.category).toSet()];final items=pos.products.where((p)=>p.active&&(category=='Tümü'||p.category==category)).toList();return Scaffold(appBar:AppBar(title:Text('Masa ${t.id}')),body:Column(children:[SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:cats.map((x)=>Padding(padding:const EdgeInsets.all(4),child:ChoiceChip(label:Text(x),selected:category==x,onSelected:(_)=>setState(()=>category=x)))).toList())),Expanded(child:LayoutBuilder(builder:(c,b){final wide=b.maxWidth>700;return wide?Row(children:[Expanded(child:_products(items)),SizedBox(width:420,child:_ticket())]):Column(children:[Expanded(child:_products(items)),SizedBox(height:b.maxHeight*.48,child:_ticket())]);} ))]));});
Widget _products(List<Product> list)=>GridView.builder(padding:const EdgeInsets.all(10),gridDelegate:const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent:170,childAspectRatio:1.45,crossAxisSpacing:8,mainAxisSpacing:8),itemCount:list.length,itemBuilder:(c,i){final p=list[i];return Card(child:InkWell(onTap:p.stock>0&&pos.can('orders')?(){if(!pos.add(t,p)){ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('Yeterli stok yok veya işlem yetkiniz bulunmuyor.')));}}:null,child:Padding(padding:const EdgeInsets.all(10),child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text(p.name,style:const TextStyle(fontWeight:FontWeight.bold)),Text(money(p.price)),if(pos.can('inventory')) Text('Stok: ${p.stock}',style:TextStyle(color:p.stock<=p.lowAt?red:Colors.black54))]))));});
Future<void> _cancelSentLine(BuildContext context,OrderLine line) async {
  final quantity=TextEditingController(text:'1'),reason=TextEditingController(),pin=TextEditingController();
  final ok=await showDialog<bool>(context:context,builder:(dialogContext)=>AlertDialog(title:const Text('Mutfağa gönderilmiş ürünü iptal et'),content:Column(mainAxisSize:MainAxisSize.min,children:[Text('Masa ${t.id} · ${line.name} · mevcut adet ${line.qty}'),TextField(controller:quantity,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'İptal edilecek adet')),TextField(controller:reason,maxLines:2,decoration:const InputDecoration(labelText:'İptal nedeni (zorunlu)')),TextField(controller:pin,keyboardType:TextInputType.number,obscureText:true,maxLength:4,decoration:const InputDecoration(labelText:'Yönetici veya kasiyer PIN'))]),actions:[TextButton(onPressed:()=>Navigator.pop(dialogContext,false),child:const Text('Vazgeç')),FilledButton(onPressed:()=>Navigator.pop(dialogContext,true),child:const Text('İptali onayla'))]));
  if(context.mounted&&ok==true){final success=pos.cancelSentLine(t,line,int.tryParse(quantity.text)??0,reason.text,pin.text.trim());if(!success)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('İptal yapılamadı. Adedi, nedeni ve yönetici/kasiyer PIN kodunu kontrol edin.')));}
  quantity.dispose();reason.dispose();pin.dispose();
}
Widget _ticket()=>Container(color:Colors.white,child:Column(children:[Padding(padding:const EdgeInsets.all(12),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('Sipariş',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),Text('Mutfak: ${kitchenLabel(t)}') ])),Expanded(child:ListView.builder(itemCount:t.items.length,itemBuilder:(c,i){final x=t.items[i];return ListTile(title:Text(x.name),subtitle:Text('${money(x.price)} × ${x.qty}'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(tooltip:x.sent?'Gönderilmiş ürünü iptal et':'Adedi azalt',onPressed:!pos.can('orders')?null:()=>x.sent?_cancelSentLine(c,x):pos.qty(t,i,-1),icon:const Icon(Icons.remove)),IconButton(onPressed:pos.can('orders')?(){if(!pos.qty(t,i,1)){ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text(x.sent?'Mutfağa gönderilen ürünün miktarı değiştirilemez. Yeni ürün satırı ekleyin.':'Stok yetersiz.')));}}:null,icon:const Icon(Icons.add))]));})),Padding(padding:const EdgeInsets.all(12),child:Column(children:[Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('Ara toplam'),Text(money(t.subtotal))]),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('İndirim'),Text(money(t.subtotal-t.total))]),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('TOPLAM',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),Text(money(t.total),style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold))]),Wrap(spacing:8,children:[if(pos.can('discount')) OutlinedButton.icon(onPressed:t.items.isEmpty?null:()=>_discount(context),icon:const Icon(Icons.percent),label:const Text('İndirim')),if(t.discount>0&&pos.can('discount')) OutlinedButton(onPressed:()=>pos.clearDiscount(t),child:const Text('İndirimi kaldır')),OutlinedButton(onPressed:!t.items.any((item)=>!item.sent)||!pos.can('orders')?null:()=>pos.sendKitchen(t),child:Text(t.items.any((item)=>!item.sent)?'Mutfağa gönder':'Gönderilecek yeni ürün yok'))]),if(pos.can('register')) SizedBox(width:double.infinity,child:FilledButton(onPressed:t.items.isEmpty||t.items.any((item)=>!item.sent)?null:()=>_pay(context),child:Text(t.items.any((item)=>!item.sent)?'Önce mutfağa gönder':'Ödeme al')))]))]));
Future<void> _discount(BuildContext context)async{final value=TextEditingController(text:t.discountPercent?t.discount.toString():(t.discount/100).toStringAsFixed(2));final reason=TextEditingController(text:t.discountReason);bool percent=t.discountPercent;final ok=await showDialog<bool>(context:context,builder:(c)=>StatefulBuilder(builder:(c,set)=>AlertDialog(title:const Text('İndirim tanımla'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:value,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'İndirim tutarı / yüzde')),SwitchListTile(title:const Text('Yüzde olarak uygula'),value:percent,onChanged:(v)=>set(()=>percent=v)),TextField(controller:reason,decoration:const InputDecoration(labelText:'İndirim nedeni'))]),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Vazgeç')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Uygula'))])));if(!context.mounted)return;if(ok==true){final n=percent?int.tryParse(value.text):parseMoney(value.text);if(n==null||!pos.setDiscount(t,n,percent,reason.text)){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('İndirim için geçerli bir tutar ve neden girin.')));}}}
Future<void> _pay(BuildContext context) async {
  final payment = await showDialog<PaymentResult>(
    context: context,
    builder: (_) => PaymentDialog(total: t.total, initialStaff: pos.currentUser),
  );
  if (!context.mounted || payment == null) return;
  if (pos.checkout(t, payment.payments, staffName: payment.staffName)) {
    Navigator.pop(context);
  } else {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Stok değişti veya ödeme tutarı eşleşmiyor. Sipariş korunmuştur.'),
    ));
  }
}
}

int? _addPart(List<PaymentPart> parts, String method, TextEditingController ctrl, int remaining) {
  final received = parseMoney(ctrl.text);
  if (received == null || received <= 0) return null;
  if (method == 'Nakit') {
    final applied = received > remaining ? remaining : received;
    parts.add(PaymentPart(method, applied, tendered: received));
    ctrl.clear();
    return remaining - applied;
  }
  if (received > remaining) return null;
  parts.add(PaymentPart(method, received));
  ctrl.clear();
  return remaining - received;
}

class PaymentResult {
  final List<PaymentPart> payments;
  final String staffName;
  const PaymentResult(this.payments, this.staffName);
}

class PaymentDialog extends StatefulWidget {
  final int total;
  final String initialStaff;
  const PaymentDialog({super.key, required this.total, required this.initialStaff});

  @override
  State<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<PaymentDialog> {
  final amount = TextEditingController();
  final staffPin = TextEditingController();
  String? staffName;
  final parts = <PaymentPart>[];
  Staff? get selectedStaff { for(final member in pos.staff) { if(member.name==staffName&&member.active)return member; } return null; }
  @override void initState(){super.initState();staffName=pos.currentUser;}
  late int remaining = widget.total;

  @override
  void dispose() {
    amount.dispose();
    staffPin.dispose();
    super.dispose();
  }

  void addPart(String method) {
    if (remaining == 0) return;
    final next = _addPart(parts, method, amount, remaining);
    if (next == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Geçerli bir tutar girin. Kart ödemesi kalan tutarı aşamaz.'),
      ));
      return;
    }
    setState(() => remaining = next);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Ödeme · ${money(widget.total)}'),
    content: SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Kalan: ${money(remaining)}'),
        DropdownButtonFormField<String>(initialValue:staffName,decoration:const InputDecoration(labelText:'Satışı yapan personel'),items:pos.staff.where((member)=>member.active).map((member)=>DropdownMenuItem(value:member.name,child:Text('${member.name} · ${member.role}'))).toList(),onChanged:(value){setState((){staffName=value;staffPin.clear();});}),
        if(selectedStaff?.pinRequired??false) TextField(controller:staffPin,keyboardType:TextInputType.number,obscureText:true,maxLength:4,decoration:const InputDecoration(labelText:'Personel PIN doğrulaması'),onChanged:(_)=>setState((){})),
        TextField(
          controller: amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Tutar (örn. 12,50)'),
        ),
        Wrap(children: ['Nakit', 'Kart'].map((method) => TextButton(
          onPressed: remaining == 0 ? null : () => addPart(method),
          child: Text('$method ekle'),
        )).toList()),
        for (final part in parts)
          Text(part.method == 'Nakit'
            ? 'Nakit: ${money(part.amount)} · Alınan: ${money(part.tendered)} · Para üstü: ${money(part.change)}'
            : 'Kart: ${money(part.amount)}'),
      ]),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('İptal')),
      FilledButton(
        onPressed: remaining == 0 && selectedStaff != null &&
          (!selectedStaff!.pinRequired || staffPin.text.trim().length == 4)
          ? () { if(selectedStaff!.pinRequired && !pos.verifyStaffPin(selectedStaff!,staffPin.text.trim())) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Personel PIN hatalı veya geçici olarak kilitli.'))); return; } Navigator.pop(context, PaymentResult(List<PaymentPart>.from(parts), staffName!)); } : null,
        child: const Text('Ödemeyi tamamla'),
      ),
    ],
  );
}

class KitchenPage extends StatelessWidget {
  final VoidCallback? onLogout;
  const KitchenPage({super.key, this.onLogout});

  String _label(KitchenState state) => switch (state) {
    KitchenState.queued => 'Kuyrukta',
    KitchenState.preparing => 'Hazırlanıyor',
    KitchenState.ready => 'Hazır',
    KitchenState.served => 'Servis edildi',
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pos,
    builder: (context, _) {
      final notices = pos.kitchenNotices.where((notice)=>!notice.acknowledged).toList();
      final activeTables = pos.tables.where((table) =>
        table.items.any((item) => item.sent && item.kitchen != KitchenState.served)).toList();
      return Scaffold(
        appBar: AppBar(
          title: const Text('Mutfak sipariş kuyruğu'),
          actions: [
            if (onLogout != null)
              IconButton(tooltip: 'Oturumu kapat', onPressed: onLogout,
                icon: const Icon(Icons.logout)),
          ],
        ),
        body: Column(children:[
          if(notices.isNotEmpty) SizedBox(height:190,child:ListView.builder(
            padding:const EdgeInsets.all(8),itemCount:notices.length,
            itemBuilder:(context,index){final notice=notices[index];return Card(color:Colors.red.shade50,child:ListTile(
              leading:const Icon(Icons.notification_important,color:red),
              title:Text('İPTAL · Masa ${notice.tableId} · ${notice.quantity} × ${notice.productName}',style:const TextStyle(fontWeight:FontWeight.bold)),
              subtitle:Text('${notice.reason} · ${notice.by} · ${bakuTimestamp(notice.at)}'),
              trailing:IconButton(tooltip:'Görüldü',onPressed:()=>pos.acknowledgeKitchenNotice(notice),icon:const Icon(Icons.check_circle_outline)),
            ));},
          )),
          Expanded(child:activeTables.isEmpty
            ? const Center(child: Text('Mutfakta bekleyen sipariş yok.'))
            : ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: activeTables.length,
                itemBuilder: (context, index) {
                  final table = activeTables[index];
                  final activeLines = table.items.where((item) =>
                    item.sent && item.kitchen != KitchenState.served).toList();
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Masa ${table.id} · ${activeLines.length} ürün bekliyor',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                          const Divider(),
                          for (final line in activeLines)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text('${line.qty} × ${line.name}',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text('Durum: ${_label(line.kitchen)}'),
                              trailing: PopupMenuButton<KitchenState>(
                                tooltip: 'Ürün durumunu değiştir',
                                onSelected: (state) => pos.setKitchenLine(table, line, state),
                                itemBuilder: (_) => [
                                  for (final state in KitchenState.values)
                                    PopupMenuItem(value: state, child: Text(_label(state))),
                                ],
                                child: const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(Icons.more_vert),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              )),
        ]),
      );
    },
  );
}

class InventoryPage extends StatelessWidget {
  const InventoryPage({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: pos,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: const Text('Stok yönetimi'),
            actions: [
              IconButton(tooltip:'Stok hareket geçmişi',onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const StockHistoryPage())),icon:const Icon(Icons.history)),
              IconButton(tooltip:'Barkod okuyucu',onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const BarcodePage())),icon:const Icon(Icons.qr_code_scanner)),
              IconButton(tooltip: 'Reçeteler ve malzemeler',
                onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const RecipePage())),
                icon: const Icon(Icons.restaurant_menu)),

              IconButton(
                onPressed: pos.can('inventory') ? () => _editProduct(context) : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          body: pos.can('inventory')
              ? ListView(
                  children: [
                    for (final product in pos.products)
                      ListTile(
                        title: Text(product.name),
                        subtitle: Text('${product.category} · Satış: ${money(product.price)} · Maliyet: ${money(product.costPrice)} · Birim kâr: ${money(product.price-product.costPrice)} · Kritik seviye: ${product.lowAt}'),
                        leading: Icon(Icons.inventory, color: product.stock <= product.lowAt ? red : green),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${product.stock}'),
                            IconButton(onPressed: () { if (!pos.stockChange(product, -1)) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Stok, açık siparişlerde rezerve edilmiş miktarın altına indirilemez.'))); }, icon: const Icon(Icons.remove)),
                            IconButton(onPressed: () => pos.stockChange(product, 1), icon: const Icon(Icons.add)),
                            Switch(value: product.active, onChanged: (value) { product.active=value; pos.log('Menü', '${product.name}: ${value ? 'aktif' : 'pasif'}'); pos.save(); }),
                            IconButton(onPressed: () => _editProduct(context, product), icon: const Icon(Icons.edit)),
                          ],
                        ),
                      ),
                  ],
                )
              : const Center(child: Text('Bu bölüm için yönetici yetkisi gerekir.')),
        ),
      );

  Future<void> _editProduct(BuildContext context, [Product? old]) async {
    final name = TextEditingController(text: old?.name ?? '');
    final category = TextEditingController(text: old?.category ?? 'Genel');
    final price = TextEditingController(text: old == null ? '' : (old.price / 100).toStringAsFixed(2));
    final cost = TextEditingController(text: old == null ? '' : (old.costPrice / 100).toStringAsFixed(2));
    final stock = TextEditingController(text: '${old?.stock ?? 0}');
    final low = TextEditingController(text: '${old?.lowAt ?? 5}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(old == null ? 'Ürün ekle' : 'Ürünü düzenle'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Ürün adı')),
            TextField(controller: category, decoration: const InputDecoration(labelText: 'Kategori')),
            TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Satış fiyatı (₼)')),
            TextField(controller: cost, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Alış maliyeti (₼)')),
            TextField(controller: stock, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Stok adedi')),
            TextField(controller: low, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Kritik stok seviyesi')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('İptal')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kaydet')),
        ],
      ),
    );
    final parsedPrice = parseMoney(price.text);
    final parsedCost = cost.text.trim().isEmpty ? 0 : parseMoney(cost.text);
    if (ok == true && name.text.trim().isNotEmpty && parsedPrice != null && parsedPrice > 0 && parsedCost != null) {
      pos.upsertProduct(Product(
        old?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        category.text.trim().isEmpty ? 'Genel' : category.text.trim(),
        name.text.trim(),
        parsedPrice,
        costPrice: parsedCost,
        stock: (int.tryParse(stock.text) ?? 0).clamp(0, 1000000).toInt(),
        lowAt: (int.tryParse(low.text) ?? 5).clamp(0, 1000000).toInt(),
      ));
    }
  }
}

class RecipePage extends StatelessWidget {
  const RecipePage({super.key});

  Future<void> _addIngredient(BuildContext context) async {
    final name = TextEditingController();
    final unit = TextEditingController(text: 'adet');
    final stock = TextEditingController(text: '0');
    final low = TextEditingController(text: '0');
    final cost = TextEditingController(text: '0');
    final ok = await showDialog<bool>(context: context, builder: (dialogContext) =>
      AlertDialog(
        title: const Text('Yeni malzeme'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Malzeme adı')),
            TextField(controller: unit, decoration: const InputDecoration(labelText: 'Birim (gram, ml, adet)')),
            TextField(controller: stock, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Mevcut miktar')),
            TextField(controller: low, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Kritik stok miktarı')),
            TextField(controller: cost, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Birim maliyet (₼)')),
          ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('İptal')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Kaydet')),
        ],
      ));
    if (ok == true) {
      final item = Ingredient(id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.text.trim(), unit: unit.text.trim(),
        stock: int.tryParse(stock.text) ?? -1, lowAt: int.tryParse(low.text) ?? -1,
        costPerUnit: parseMoney(cost.text) ?? -1);
      if (!pos.addIngredient(item) && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Malzeme bilgileri geçersiz.')));
      }
    }
    name.dispose(); unit.dispose(); stock.dispose(); low.dispose(); cost.dispose();
  }

  Future<void> _editRecipe(BuildContext context, Product product) async {
    final lines = List<RecipeLine>.from(pos.recipes[product.id] ?? const []);
    String? selectedId;
    final amount = TextEditingController(text: '1');
    final result = await showDialog<List<RecipeLine>>(context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) =>
        AlertDialog(
          title: Text('${product.name} reçetesi'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
            children: [
              if (lines.isEmpty) const Text('Bu ürün için henüz malzeme tanımlanmadı.'),
              for (final line in lines)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(pos.ingredients.firstWhere((item) => item.id == line.ingredientId).name),
                  subtitle: Text('${line.quantity} ${pos.ingredients.firstWhere((item) => item.id == line.ingredientId).unit} / ürün'),
                  trailing: IconButton(icon: const Icon(Icons.delete_outline),
                    onPressed: () => setDialogState(() => lines.remove(line))),
                ),
              const Divider(),
              DropdownButtonFormField<String>(
                initialValue: selectedId,
                decoration: const InputDecoration(labelText: 'Malzeme seç'),
                items: pos.ingredients.map((item) => DropdownMenuItem(
                  value: item.id, child: Text('${item.name} (${item.unit})'))).toList(),
                onChanged: (value) => setDialogState(() => selectedId = value),
              ),
              TextField(controller: amount, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Ürün başına miktar')),
              Align(alignment: Alignment.centerRight, child: TextButton.icon(
                onPressed: selectedId == null || int.tryParse(amount.text) == null ||
                    int.parse(amount.text) <= 0 || lines.any((line) => line.ingredientId == selectedId)
                  ? null : () => setDialogState(() {
                    lines.add(RecipeLine(ingredientId: selectedId!, quantity: int.parse(amount.text)));
                    selectedId = null; amount.text = '1';
                  }),
                icon: const Icon(Icons.add), label: const Text('Malzeme ekle'))),
            ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('İptal')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, lines), child: const Text('Reçeteyi kaydet')),
          ],
        )));
    if (result != null && !pos.setRecipe(product, result) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reçete kaydedilemedi.')));
    }
    amount.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pos,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Malzemeler ve ürün reçeteleri'),
        actions: [IconButton(onPressed: pos.can('inventory') ? () => _addIngredient(context) : null,
          icon: const Icon(Icons.add), tooltip: 'Malzeme ekle')]),
      body: pos.can('inventory') ? ListView(padding: const EdgeInsets.all(12), children: [
        const Text('Malzeme stokları', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        if (pos.ingredients.isEmpty) const ListTile(title: Text('Henüz malzeme eklenmedi.')),
        for (final ingredient in pos.ingredients)
          Card(child: ListTile(
            leading: Icon(Icons.inventory_2,
              color: ingredient.stock - pos.reservedIngredientStock(ingredient.id) <= ingredient.lowAt ? red : green),
            title: Text(ingredient.name),
            subtitle: Text('${ingredient.stock} ${ingredient.unit} · Birim maliyet ${money(ingredient.costPerUnit)} · Rezerve ${pos.reservedIngredientStock(ingredient.id)}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(onPressed: () => pos.adjustIngredient(ingredient, -1), icon: const Icon(Icons.remove)),
              IconButton(onPressed: () => pos.adjustIngredient(ingredient, 1), icon: const Icon(Icons.add)),
            ]),
          )),
        const Divider(),
        const Text('Ürün reçeteleri', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        for (final product in pos.products.where((item) => item.active))
          Card(child: ListTile(
            title: Text(product.name),
            subtitle: Text((pos.recipes[product.id] ?? const <RecipeLine>[])
              .map((line) {
                final ingredient = pos.ingredients.where((item) => item.id == line.ingredientId);
                return ingredient.isEmpty ? 'Silinmiş malzeme' : '${ingredient.first.name}: ${line.quantity} ${ingredient.first.unit}';
              }).join(' · ').isEmpty ? 'Reçete tanımlanmamış' :
              (pos.recipes[product.id] ?? const <RecipeLine>[])
                .map((line) {
                  final ingredient = pos.ingredients.where((item) => item.id == line.ingredientId);
                  return ingredient.isEmpty ? 'Silinmiş malzeme' : '${ingredient.first.name}: ${line.quantity} ${ingredient.first.unit}';
                }).join(' · ')),
            trailing: IconButton(icon: const Icon(Icons.edit),
              onPressed: () => _editRecipe(context, product)),
          )),
      ]) : const Center(child: Text('Malzeme yönetimi için yönetici girişi gerekir.')),
    ),
  );
}

class StockHistoryPage extends StatelessWidget {
  const StockHistoryPage({super.key});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pos,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Stok hareket geçmişi')),
      body: pos.stockMovements.isEmpty
        ? const Center(child: Text('Henüz stok hareketi yok.'))
        : ListView.builder(
            itemCount: pos.stockMovements.length,
            itemBuilder: (context, index) {
              final movement = pos.stockMovements[pos.stockMovements.length - 1 - index];
              return ListTile(
                title: Text('${movement.productName} · ${movement.type} · ${movement.quantity} adet'),
                subtitle: Text('${movement.beforeStock} → ${movement.afterStock} · ${movement.note}'),
                trailing: Text(money(movement.productCost * movement.quantity)),
              );
            },
          ),
    ),
  );
}
class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});
  Future<void> _printReceipt(BuildContext context, Sale sale) async {
    final ok = await ReceiptPrinter.printSale(sale);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
      ok ? 'Fiş yazdırma penceresi açıldı.' : 'Fiş hazırlanamadı. Yazıcı ve PDF desteğini kontrol edin.')));
  }
  Future<void> _refund(BuildContext context,Sale sale) async {
    final saleIndex=pos.sales.indexOf(sale); final remaining=pos.remainingRefundable(saleIndex);
    if(remaining<=0)return;
    final amount=TextEditingController(text:(remaining/100).toStringAsFixed(2)),reason=TextEditingController(),pin=TextEditingController(); bool returnStock=false;
    final ok=await showDialog<bool>(context:context,builder:(dialogContext)=>StatefulBuilder(builder:(dialogContext,setDialog)=>AlertDialog(title:Text('Satış #${saleIndex+1} için iade'),content:Column(mainAxisSize:MainAxisSize.min,children:[Text('İade edilebilir tutar: ${money(remaining)}'),TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'İade tutarı (₼)')),TextField(controller:reason,maxLines:2,decoration:const InputDecoration(labelText:'İade nedeni (zorunlu)')),TextField(controller:pin,keyboardType:TextInputType.number,obscureText:true,maxLength:4,decoration:const InputDecoration(labelText:'Yönetici PIN')),CheckboxListTile(contentPadding:EdgeInsets.zero,value:returnStock,onChanged:(value)=>setDialog(()=>returnStock=value??false),title:const Text('Ürünleri ve reçete malzemelerini stoğa geri al'),subtitle:const Text('Stok iadesi yalnızca satışın kalan tutarının tamamı iade edilirse yapılır.'))]),actions:[TextButton(onPressed:()=>Navigator.pop(dialogContext,false),child:const Text('Vazgeç')),FilledButton(onPressed:()=>Navigator.pop(dialogContext,true),child:const Text('İadeyi kaydet'))])));
    if(context.mounted&&ok==true){final success=pos.refundSale(saleIndex,parseMoney(amount.text) ?? 0,reason.text,pin.text.trim(),returnStock:returnStock);ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(success?'İade kaydedildi ve kasa çıkışı işlendi.':'İade yapılamadı. PIN, tutar, açık kasa ve stok durumunu kontrol edin.')));}
    amount.dispose();reason.dispose();pin.dispose();
  }
  Future<void> _addExpense(BuildContext context) async {final amount=TextEditingController(),category=TextEditingController(text:'Diğer'),note=TextEditingController();final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('İşletme gideri ekle'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Tutar (₼)')),TextField(controller:category,decoration:const InputDecoration(labelText:'Kategori')),TextField(controller:note,decoration:const InputDecoration(labelText:'Açıklama'))]),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Kaydet'))]));if(ok==true&&!pos.addExpense(parseMoney(amount.text) ?? 0,category.text,note.text)&&context.mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Gider kaydedilemedi.')));amount.dispose();category.dispose();note.dispose();}
  Future<void> _exportCsv(BuildContext context) async {try{final dir=await getApplicationDocumentsDirectory();final file=File('${dir.path}/restoram-rapor-${dayKey(azWallTime(azNow()))}.csv');await file.writeAsString(pos.buildCsv(),flush:true);if(context.mounted)showDialog<void>(context:context,builder:(c)=>AlertDialog(title:const Text('CSV raporu hazır'),content:SelectableText(file.path),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Kapat'))]));}catch(e){if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('CSV oluşturulamadı: $e')));}}
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pos,
    builder: (context, _) {
      final today = dayKey(azWallTime(azNow()));
      final todaySales = pos.sales.where((sale) => sale.date == today).toList();
      final weekStart = azWallTime(azNow()).subtract(const Duration(days: 6));
      final weekSales = pos.sales.where((sale) {
        final date = DateTime.tryParse(sale.date);
        return date != null && !date.isBefore(DateTime(weekStart.year, weekStart.month, weekStart.day));
      }).toList();
      final cash = todaySales.fold(0, (sum, sale) => sum + sale.payments.where((part) => part.method == 'Nakit').fold(0, (value, part) => value + part.amount));
      final card = todaySales.fold(0, (sum, sale) => sum + sale.payments.where((part) => part.method == 'Kart').fold(0, (value, part) => value + part.amount));
      final units = weekSales.fold<int>(0,(sum,sale)=>sum+sale.items.fold<int>(0,(n,item)=>n+(sale.isRefund?-item.qty:item.qty)));
      final productTotals = <String, int>{};
      for (final sale in weekSales) { for (final item in sale.items) { productTotals[item.name] = (productTotals[item.name] ?? 0) + (sale.isRefund ? -item.qty : item.qty); } }
      final topProducts = productTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      final todayExpenses=pos.expenses.where((e)=>e.date==today).toList();
      final weekExpenses=pos.expenses.where((e){final d=DateTime.tryParse(e.date);return d!=null&&!d.isBefore(DateTime(weekStart.year,weekStart.month,weekStart.day));}).toList();
      final bakuNow=azWallTime(azNow()); final monthStart=DateTime(bakuNow.year,bakuNow.month,1);
      final monthSales=pos.sales.where((s){final d=DateTime.tryParse(s.date);return d!=null&&!d.isBefore(monthStart);}).toList();
      final monthExpenses=pos.expenses.where((e){final d=DateTime.tryParse(e.date);return d!=null&&!d.isBefore(monthStart);}).toList();
      final salesByStaff = <String, List<Sale>>{};
      for (final sale in pos.sales) {
        (salesByStaff[sale.staff] ??= <Sale>[]).add(sale);
      }
      final staffRows = salesByStaff.entries.toList()
        ..sort((a, b) => b.value.fold<int>(0, (sum, sale) => sum + sale.total)
            .compareTo(a.value.fold<int>(0, (sum, sale) => sum + sale.total)));
      final recentShifts = pos.registerSessions.reversed.take(10).toList();

      int revenue(List<Sale> xs)=>xs.fold(0,(sum,s)=>sum+s.total);
      int cost(List<Sale> xs)=>xs.fold(0,(sum,s)=>sum+pos.costOfSale(s));
      int expenseTotal(List<Expense> xs)=>xs.fold(0,(sum,e)=>sum+e.amount);
      Widget profitCard(String label,List<Sale> sales,List<Expense> expenses)=>Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:16)),Wrap(spacing:8,runSpacing:8,children:[_metric('Ciro',money(revenue(sales))),_metric('Ürün maliyeti',money(cost(sales))),_metric('Brüt kâr',money(revenue(sales)-cost(sales))),_metric('Gider',money(expenseTotal(expenses))),_metric('Net kâr',money(revenue(sales)-cost(sales)-expenseTotal(expenses)))])])));
      return Scaffold(
        appBar: AppBar(title: const Text('Satış ve performans raporu')),
        body: pos.can('reports') ? ListView(padding: const EdgeInsets.all(12), children: [
          const Text('Bugünkü kasa', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _metric('Bugünkü ciro', money(todaySales.fold(0, (sum, sale) => sum + sale.total))),
            _metric('Satış adedi', '${todaySales.where((sale)=>!sale.isRefund).length}'), _metric('Nakit', money(cash)), _metric('Kart', money(card)),
          ]),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const RegisterPage())),
            icon: const Icon(Icons.point_of_sale),
            label: const Text('Kasa vardiyası ve nakit hareketleri'),
          ),
          const SizedBox(height: 12),
          const Text('Son 7 gün', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _metric('7 günlük ciro', money(weekSales.fold(0, (sum, sale) => sum + sale.total))),
            _metric('Satılan ürün', '$units adet'),
          ]),
          const SizedBox(height: 12),
          const Text('En çok satılan ürünler', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          if (topProducts.isEmpty) const ListTile(title: Text('Henüz satış verisi yok.')),
          for (final item in topProducts.take(5)) ListTile(leading: const Icon(Icons.trending_up), title: Text(item.key), trailing: Text('${item.value} adet')),
          const Divider(),
          const Text('Personel performansı', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          if (staffRows.isEmpty) const ListTile(title: Text('Personel bazlı satış kaydı bulunmuyor.')),
          for (final entry in staffRows)
            Builder(builder: (_) {
              final staffSales = entry.value;
              final total = staffSales.fold<int>(0, (sum, sale) => sum + sale.total);
              final unitsSold = staffSales.expand((sale) => sale.items)
                  .fold<int>(0, (sum, item) => sum + item.qty);
              final cashTotal = staffSales.expand((sale) => sale.payments)
                  .where((part) => part.method == 'Nakit')
                  .fold<int>(0, (sum, part) => sum + part.amount);
              final cardTotal = staffSales.expand((sale) => sale.payments)
                  .where((part) => part.method == 'Kart')
                  .fold<int>(0, (sum, part) => sum + part.amount);
              return Card(child: ExpansionTile(
                title: Text(entry.key),
                subtitle: Text('${staffSales.length} satış · Ciro ${money(total)}'),
                children: [
                  ListTile(title: const Text('Satılan ürün'), trailing: Text('$unitsSold adet')),
                  ListTile(title: const Text('Ortalama fiş'), trailing: Text(money(total ~/ staffSales.length))),
                  ListTile(title: const Text('Nakit / Kart'), trailing: Text('${money(cashTotal)} / ${money(cardTotal)}')),
                ],
              ));
            }),
          const SizedBox(height: 12),
          const Text('Kasa vardiyası özeti', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          if (recentShifts.isEmpty) const ListTile(title: Text('Henüz vardiya kaydı yok.')),
          for (final shift in recentShifts)
            Card(child: ListTile(
              leading: Icon(shift.isOpen ? Icons.lock_open : Icons.lock),
              title: Text('${bakuTimestamp(shift.openedAt)} · ${shift.isOpen ? 'Açık' : 'Kapalı'}'),
              subtitle: Text('Açılış ${money(shift.openingCash)} · Beklenen ${money(shift.expectedCash ?? pos.expectedRegisterCash(shift))}'),
              trailing: shift.closingCash == null || shift.expectedCash == null
                ? null : Text('Fark ${money(shift.closingCash! - shift.expectedCash!)}'),
            )),
          const Divider(),
          const Text('Kârlılık raporları',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),profitCard('Bugün',todaySales,todayExpenses),profitCard('Son 7 gün',weekSales,weekExpenses),profitCard('Bu ay',monthSales,monthExpenses),OutlinedButton.icon(onPressed:()=>_addExpense(context),icon:const Icon(Icons.add_card),label:const Text('İşletme gideri ekle')),OutlinedButton.icon(onPressed:()=>_exportCsv(context),icon:const Icon(Icons.download),label:const Text('Raporları CSV dışa aktar')),for(final expense in pos.expenses.reversed.take(30))ListTile(dense:true,title:Text('${expense.category} · ${money(expense.amount)}'),subtitle:Text('${expense.date} · ${expense.note}')),const Text('Satış geçmişi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          for (final sale in pos.sales.reversed) Card(child: ExpansionTile(
            title: Text('${sale.isRefund?'İADE':'SATIŞ'} · ${sale.date} · ${sale.time} · Masa ${sale.table} · ${money(sale.total)}'),
            subtitle: Text(sale.isRefund?'Neden: ${sale.reason}':'İndirim: ${money(sale.discount)}'),
            children: [
              for (final item in sale.items) ListTile(dense: true, title: Text('${item.qty} × ${item.name}'), trailing: Text(money(item.qty * item.price))),
              Padding(padding: const EdgeInsets.all(12), child: Text('Ödeme: ${sale.payments.map((part) => part.method == 'Nakit' ? 'Nakit ${money(part.amount)} (alınan ${money(part.tendered)}, para üstü ${money(part.change)})' : part.method == 'İade' ? 'İade ${money(part.amount)}' : 'Kart ${money(part.amount)}').join(' + ')}')),
              Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing:8,children:[OutlinedButton.icon(onPressed:()=>_printReceipt(context,sale), icon:const Icon(Icons.print), label:const Text('Fişi yazdır / PDF')),if(pos.isAdmin&&!sale.isRefund&&pos.remainingRefundable(pos.sales.indexOf(sale))>0)OutlinedButton.icon(onPressed:pos.activeRegister==null?null:()=>_refund(context,sale),icon:const Icon(Icons.assignment_return),label:Text('İade et · ${money(pos.remainingRefundable(pos.sales.indexOf(sale)))}'))])),
            ],
          )),
        ]) : const Center(child: Text('Raporlar için yönetici girişi gerekir.')),
      );
    },
  );
}

Widget _metric(String title,String value)=>SizedBox(width:160,child:Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title),Text(value,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:19))]))));

class StaffManagerPage extends StatefulWidget { const StaffManagerPage({super.key}); @override State<StaffManagerPage> createState()=>_StaffManagerPageState(); }
class _StaffManagerPageState extends State<StaffManagerPage>{
  Future<void> _add() async {
    final name=TextEditingController(),pin=TextEditingController(),confirm=TextEditingController(); String role='Garson';
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,set)=>AlertDialog(title:const Text('Personel ekle'),content:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:name,decoration:const InputDecoration(labelText:'Ad soyad')),
      DropdownButtonFormField<String>(initialValue:role,decoration:const InputDecoration(labelText:'Görev'),items:const ['Garson','Kasiyer','Mutfak'].map((r)=>DropdownMenuItem(value:r,child:Text(r))).toList(),onChanged:(v)=>set(()=>role=v??'Garson')),
      if(role!='Garson') TextField(controller:pin,keyboardType:TextInputType.number,obscureText:true,maxLength:4,decoration:const InputDecoration(labelText:'Personel PIN (4 rakam)')),
      if(role!='Garson') TextField(controller:confirm,keyboardType:TextInputType.number,obscureText:true,maxLength:4,decoration:const InputDecoration(labelText:'PIN tekrar')),
      if(role=='Garson') const Text('Garson hesabı PIN olmadan açılır. Yalnızca masalara sipariş ekleyebilir.'),
    ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Ekle'))])));
    final pinValid=role=='Garson'||(pin.text.trim()==confirm.text.trim());
    if(ok==true&&(!pinValid||!pos.addStaff(name.text,role,role=='Garson'?null:pin.text.trim()))&&mounted)
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Ad benzersiz olmalı; PIN eşleşmeli ve 1234 dışında 4 rakam olmalı.')));
    name.dispose();pin.dispose();confirm.dispose();
  }
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(context,_)=>Scaffold(appBar:AppBar(title:const Text('Personel listesi'),actions:[IconButton(onPressed:_add,icon:const Icon(Icons.person_add))]),body:ListView(children:[
    for(final member in pos.staff.where((x)=>x.name!='Admin'))ListTile(title:Text(member.name),subtitle:Text(member.role),trailing:Switch(value:member.active,onChanged:(v)=>pos.setStaffActive(member,v))),
    if(pos.staff.length==1)const ListTile(title:Text('Henüz personel eklenmedi.')),
  ])));
}

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pos,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Yönetim ve güvenlik')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const Card(child: ListTile(leading: Icon(Icons.admin_panel_settings),title:Text('Yönetici kontrolü'),subtitle:Text('Personel listesini yönetin ve satışları personele atayın.'))),
        OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const StaffManagerPage())),icon:const Icon(Icons.groups),label:const Text('Personel listesi ve yönetimi')),
        OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const SuppliersPage())),icon:const Icon(Icons.local_shipping),label:const Text('Tedarikçiler ve mal alımları')),
        OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const CustomersReservationsPage())),icon:const Icon(Icons.event_seat),label:const Text('Müşteriler ve masa rezervasyonları')),
        OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const AnalyticsPage())),icon:const Icon(Icons.insights),label:const Text('Gelişmiş analiz paneli')),
        OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const BarcodePage())),icon:const Icon(Icons.qr_code_scanner),label:const Text('Barkod okuyucu ve eşleştirme')),
        OutlinedButton.icon(onPressed: () => _changePin(context), icon: const Icon(Icons.lock_reset), label: const Text('Yönetici PIN kodunu değiştir')),
        OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupManagerPage())), icon: const Icon(Icons.restore), label: const Text('Yedekleri görüntüle ve geri yükle')),
        OutlinedButton.icon(onPressed: () => _runIntegrityCheck(context), icon: const Icon(Icons.fact_check), label: const Text('Veri bütünlüğünü denetle')),
        const SizedBox(height: 12),
        const Text('Veri güvenliği', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        const ListTile(leading: Icon(Icons.storage), title: Text('SQLite yerel veritabanı'), subtitle: Text('İşlemler atomik kayıtla saklanır. Eski yerel kayıt ilk açılışta otomatik taşınır.')),
        const ListTile(leading: Icon(Icons.backup), title: Text('Otomatik yedekleme'), subtitle: Text('Günlük JSON yedeği alınır ve son 7 yedek saklanır. Yedekler cihazda kalır.')),
        const Divider(),
        const Text('Son işlemler', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        if (pos.audit.isEmpty) const ListTile(title: Text('Henüz işlem kaydı yok.')),
        for (final entry in pos.audit.take(100)) ListTile(dense: true, title: Text('${entry.action}: ${entry.detail}'), subtitle: Text('${entry.at} · ${entry.user}')),
      ]),
    ),
  );
  Future<void> _runIntegrityCheck(BuildContext context) async {
    final issues = await pos.integrityCheck();
    if (!context.mounted) return;
    showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
      title: Text(issues.isEmpty ? 'Veri denetimi başarılı' : 'Veri denetimi: ${issues.length} bulgu'),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: issues.isEmpty
          ? [const ListTile(leading: Icon(Icons.verified, color: green),
              title: Text('Veritabanı, stok rezervasyonları, ödemeler ve yedekler tutarlı görünüyor.'))]
          : [for (final issue in issues) ListTile(
              dense: true, leading: const Icon(Icons.warning_amber, color: red),
              title: Text(issue))],
      ))),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Kapat'))],
    ));
  }

  Future<void> _changePin(BuildContext context) async {
    final oldPin = TextEditingController(), newPin = TextEditingController(), confirmPin = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Yönetici PIN değiştir'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: oldPin, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Mevcut PIN')),
        TextField(controller: newPin, obscureText: true, keyboardType: TextInputType.number, maxLength: 4, decoration: const InputDecoration(labelText: 'Yeni 4 haneli PIN')),
        TextField(controller: confirmPin, obscureText: true, keyboardType: TextInputType.number, maxLength: 4, decoration: const InputDecoration(labelText: 'Yeni PIN tekrar')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('İptal')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Değiştir'))],
    ));
    if (ok == true) {
      final admin = pos.staff.firstWhere((member) => member.name == 'Admin');
      final value = newPin.text.trim();
      final valid = pos.verifyAdminPin(oldPin.text.trim()) && RegExp(r'^[0-9]{4}$').hasMatch(value) && value != '1234' && value == confirmPin.text.trim();
      if (valid) { admin.setPin(value); pos.pinSecurity.remove('staff:Admin'); pos.log('Güvenlik', 'Yönetici PIN kodu değiştirildi'); pos.save(); }
      else if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mevcut PIN yanlış veya yeni PIN geçersiz.')));
    }
    oldPin.dispose(); newPin.dispose(); confirmPin.dispose();
  }
}

class BackupManagerPage extends StatefulWidget {
  const BackupManagerPage({super.key});
  @override
  State<BackupManagerPage> createState() => _BackupManagerPageState();
}

class _BackupManagerPageState extends State<BackupManagerPage> {
  late Future<List<BackupFile>> backups;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    backups = pos.listBackups();
  }

  Future<void> _exportBackup() async {
    setState(() => busy = true);
    try {
      final filePath = await pos.exportBackup();
      await Share.shareXFiles([XFile(filePath)], text: 'Restaurant POS yerel veri yedeği');
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yedek dışa aktarılamadı: $error')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _importBackup() async {
    setState(() => busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json'], withData: true);
      if (result == null || result.files.isEmpty) return;
      final selected = result.files.single;
      final bytes = selected.bytes ?? (selected.path != null ? await File(selected.path!).readAsBytes() : null);
      if (bytes == null || bytes.isEmpty || bytes.length > 20 * 1024 * 1024) {
        throw const FormatException('Dosya boş, okunamıyor veya 20 MB sınırını aşıyor.');
      }
      final payload = utf8.decode(bytes);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Dosyadan yedek geri yüklensin mi?'),
          content: Text('${selected.name} dosyası doğrulanacak. Geçerliyse mevcut verilerin güvenlik yedeği alınarak değiştirilecek.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('İptal')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Doğrula ve yükle')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final success = await pos.restoreBackup(payload);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success ? 'Dosyadaki yedek başarıyla geri yüklendi.' : 'Yedek doğrulanamadı. Mevcut veriler korundu.')));
      if (success) Navigator.pop(context);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Yedek içe aktarılamadı: $error')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  Future<void> _restore(BackupFile backup) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Yedek geri yüklensin mi?'),
        content: Text('${backup.name} dosyasındaki veriler mevcut kayıtların yerine geçecek. Önce mevcut veriler ayrıca güvenlik yedeğine alınacak.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('İptal')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Geri yükle')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    var success = false;
    try {
      final payload = await pos.readBackup(backup.name);
      if (payload != null) success = await pos.restoreBackup(payload);
    } catch (_) {
      success = false;
    }
    if (!mounted) return;
    setState(() {
      busy = false;
      backups = pos.listBackups();
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(success ? 'Yedek başarıyla geri yüklendi.' : 'Yedek geri yüklenemedi. Mevcut veriler korundu.'),
    ));
    if (success) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Yedekler'), actions: [
      IconButton(tooltip: 'Dosyadan yedek içe aktar', onPressed: busy ? null : _importBackup,
        icon: const Icon(Icons.file_open)),
      IconButton(tooltip: 'Yedeği dışa aktar', onPressed: busy ? null : _exportBackup,
        icon: const Icon(Icons.ios_share)),
    ]),
    body: FutureBuilder<List<BackupFile>>(
      future: backups,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const Center(child: Text('Yedek listesi okunamadı.'));
        }
        final files = snapshot.data ?? [];
        if (files.isEmpty) {
          return const Center(child: Text('Henüz geri yüklenebilir yedek bulunmuyor.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: files.length,
          itemBuilder: (context, index) {
            final file = files[index];
            return Card(child: ListTile(
              leading: const Icon(Icons.backup),
              title: Text(file.name),
              subtitle: Text('${stamp(azWallTime(file.modifiedAt))} · ${(file.sizeBytes / 1024).toStringAsFixed(1)} KB'),
              trailing: busy ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator()) : IconButton(
                tooltip: 'Geri yükle',
                icon: const Icon(Icons.restore),
                onPressed: () => _restore(file),
              ),
            ));
          },
        );
      },
    ),
  );
}

class RecoveryPage extends StatefulWidget {
  const RecoveryPage({super.key});
  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  late Future<List<BackupFile>> backups;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    backups = pos.listBackups();
  }

  Future<void> _restore(BackupFile backup) async {
    setState(() => busy = true);
    var restored = false;
    try {
      final payload = await pos.readBackup(backup.name);
      if (payload != null) restored = await pos.restoreBackup(payload);
    } catch (_) {
      restored = false;
    }
    if (!mounted) return;
    if (restored && mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const Home()),
        (route) => false,
      );
      return;
    }
    setState(() {
      busy = false;
      backups = pos.listBackups();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Bu yedek doğrulanamadı. Mevcut veriler değiştirilmedi.')),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Veri kurtarma')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.warning_amber_rounded, size: 52, color: Colors.orange),
        const SizedBox(height: 12),
        const Text('Yerel veriler okunamadı',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Güvenlik için giriş ve kayıt işlemleri durduruldu. Bozuk veri otomatik olarak varsayılan verilerle değiştirilmedi. Bir sağlam yedek seçerek geri yükleyin.'),
        const SizedBox(height: 20),
        const Text('Bulunan yedekler', style: TextStyle(fontWeight: FontWeight.bold)),
        FutureBuilder<List<BackupFile>>(
          future: backups,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()));
            }
            if (snapshot.hasError || (snapshot.data ?? []).isEmpty) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('Geri yüklenebilir yedek bulunamadı. Bozuk dosya silinmedi; destek için korunuyor.'));
            }
            final files = snapshot.data!;
            return Column(children: [
              for (final file in files)
                Card(child: ListTile(
                  leading: const Icon(Icons.backup),
                  title: Text(file.name),
                  subtitle: Text('${stamp(azWallTime(file.modifiedAt))} · ${(file.sizeBytes / 1024).toStringAsFixed(1)} KB'),
                  trailing: IconButton(
                    tooltip: 'Bu yedeği geri yükle',
                    onPressed: busy ? null : () => _restore(file),
                    icon: busy ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator()) : const Icon(Icons.restore),
                  ),
                )),
            ]);
          },
        ),
      ],
    ),
  );
}

class PinGate extends StatefulWidget {
  final VoidCallback onAuthenticated;
  final ValueChanged<Staff> onStaffSelected;
  const PinGate({super.key, required this.onAuthenticated, required this.onStaffSelected});
  @override State<PinGate> createState() => _PinGateState();
}
class _PinGateState extends State<PinGate> {
  final pin = TextEditingController();
  final confirm = TextEditingController();
  String? error;
  late bool setupRequired;
  Staff get admin => pos.staff.firstWhere((s) => s.name == 'Admin', orElse: () => pos.staff.first);
  @override void initState() { super.initState(); setupRequired=admin.verifyPin('1234'); }
  @override void dispose() { pin.dispose(); confirm.dispose(); super.dispose(); }
  Future<void> _chooseStaff() async {
    final members = pos.staff.where((member) => member.active && member.role != 'Yönetici').toList();
    if (members.isEmpty) {
      setState(() => error = 'Henüz aktif personel hesabı yok.');
      return;
    }
    final selected = await showDialog<Staff>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Personel seç'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final member in members)
            ListTile(
              leading: Icon(member.role == 'Mutfak' ? Icons.soup_kitchen :
                member.role == 'Kasiyer' ? Icons.point_of_sale : Icons.person_outline),
              title: Text(member.name), subtitle: Text(member.role),
              onTap: () => Navigator.pop(dialogContext, member),
            ),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext),
          child: const Text('İptal'))],
      ),
    );
    if (!mounted || selected == null) return;
    String? staffPin;
    if (selected.pinRequired) {
      final controller = TextEditingController();
      staffPin = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('${selected.name} · PIN girişi'),
          content: TextField(
            controller: controller, autofocus: true,
            keyboardType: TextInputType.number, obscureText: true, maxLength: 4,
            decoration: const InputDecoration(labelText: '4 haneli personel PIN'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('İptal')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Giriş yap')),
          ],
        ),
      );
      controller.dispose();
      if (!mounted || staffPin == null) return;
    }
    if (!pos.loginAsStaff(selected, pin: staffPin)) {
      setState(() => error = 'Personel PIN kodu hatalı veya hesap kullanıma kapalı.');
      return;
    }
    widget.onStaffSelected(selected);
  }
  void submit() {
    final value = pin.text.trim();
    if (!RegExp(r'^[0-9]{4}$').hasMatch(value) || (setupRequired && value == '1234')) { setState(() => error = '4 rakamlı, varsayılan olmayan bir PIN girin.'); return; }
    if (setupRequired) {
      if (value != confirm.text.trim()) { setState(() => error = 'PIN kodları eşleşmiyor.'); return; }
      admin.setPin(value); setupRequired=false; pos.pinSecurity.remove('staff:Admin'); pos.currentUser = admin.name; pos.log('Güvenlik', 'Yönetici PIN kodu oluşturuldu'); pos.save(); widget.onAuthenticated(); return;
    }
    if (pos.verifyAdminPin(value)) { pos.currentUser = admin.name; widget.onAuthenticated(); }
    else { final remaining=pos.pinLockRemainingSeconds('staff:Admin'); setState(() => error = remaining>0 ? 'Çok fazla hatalı deneme. $remaining saniye bekleyin.' : 'PIN hatalı.'); pin.clear(); }
  }
  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: ink,
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: Card(
      margin: const EdgeInsets.all(24),
      child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const PosLogo(size: 120),
        const SizedBox(height: 16),
        Text(setupRequired ? 'Yönetici PIN kodunu oluştur' : 'Yönetici girişi', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        TextField(controller: pin, keyboardType: TextInputType.number, obscureText: true, maxLength: 4, decoration: InputDecoration(labelText: setupRequired ? 'Yeni 4 haneli PIN' : 'Yönetici PIN'), onSubmitted: (_) => submit()),
        if (setupRequired) TextField(controller: confirm, keyboardType: TextInputType.number, obscureText: true, maxLength: 4, decoration: const InputDecoration(labelText: 'PIN tekrar')),
        if (error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(error!, style: const TextStyle(color: red))),
        Row(children:[
          Expanded(child:FilledButton(onPressed:submit,child:Text(
            setupRequired?'PIN oluştur ve devam et':'Yönetici girişi',
            maxLines:1,softWrap:false,overflow:TextOverflow.ellipsis,
          ))),
          const SizedBox(width:8),
          TextButton.icon(onPressed:_chooseStaff,icon:const Icon(Icons.groups),
            label:const Text('Personel',maxLines:1,softWrap:false)),
        ]),
      ])),
    ))),
  );
}


class RegisterPage extends StatelessWidget {
  const RegisterPage({super.key});

  Future<int?> _amountDialog(BuildContext context, String title,
      {required String label, String initial = '', bool allowZero = false}) async {
    final controller = TextEditingController(text: initial);
    String? error;
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: label, errorText: error),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext),
              child: const Text('İptal')),
            FilledButton(
              onPressed: () {
                final amount = parseMoney(controller.text, allowZero: allowZero);
                if (amount == null) {
                  setDialogState(() => error = 'Geçerli bir tutar girin.');
                  return;
                }
                Navigator.pop(dialogContext, amount);
              },
              child: const Text('Devam et'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return value;
  }

  Future<String?> _noteDialog(BuildContext context, String title) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true, maxLines: 2,
          decoration: const InputDecoration(labelText: 'Not / neden')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext),
            child: const Text('İptal')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Kaydet')),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _open(BuildContext context) async {
    final amount = await _amountDialog(context, 'Kasayı aç', label: 'Açılış nakdi (₼)', allowZero: true);
    if (!context.mounted || amount == null) return;
    final note = await _noteDialog(context, 'Açılış notu');
    if (!context.mounted || note == null) return;
    final success = pos.openRegister(amount, note: note);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(success ? 'Kasa açıldı.' : 'Kasa açılamadı.')));
  }

  Future<void> _movement(BuildContext context, String type) async {
    final amount = await _amountDialog(context,
      type == 'Giriş' ? 'Kasaya para ekle' : 'Kasadan para çıkar',
      label: 'Tutar (₼)');
    if (!context.mounted || amount == null) return;
    final note = await _noteDialog(context, 'İşlem açıklaması');
    if (!context.mounted || note == null) return;
    final success = pos.addCashMovement(type, amount, note);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(success ? 'Nakit hareketi kaydedildi.' :
        'İşlem yapılamadı. Tutarı ve kasa bakiyesini kontrol edin.')));
  }

  Future<void> _close(BuildContext context, RegisterSession session) async {
    final expected = pos.expectedRegisterCash(session);
    final amount = await _amountDialog(context, 'Kasayı kapat',
      label: 'Sayılmış nakit (₼)', allowZero: true);
    if (!context.mounted || amount == null) return;
    final success = pos.closeRegister(amount);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(success ? 'Kasa bağlandı. Fərq: ${money(amount - expected)}' :
        'Kasa bağlana bilmədi.')));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pos,
    builder: (context, _) {
      final session = pos.activeRegister;
      final sessions = pos.registerSessions.reversed.toList();
      return Scaffold(
        appBar: AppBar(title: const Text('Kasa ve vardiya yönetimi')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          Card(child: Padding(padding: const EdgeInsets.all(16),
            child: session == null
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Aktiv kasa növbəsi yoxdur.',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 8),
                  const Text('Yeni vardiya açarken kasadaki başlangıç nakit tutarını girin.'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: pos.can('register') ? () => _open(context) : null,
                    icon: const Icon(Icons.lock_open), label: const Text('Kasayı aç')),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('KASA AÇIK',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  Text('Açılış: ${bakuTimestamp(session.openedAt)}'),
                  const Divider(),
                  _metric('Açılış nakdi', money(session.openingCash)),
                  _metric('Nakit satış', money(pos.cashSalesForSession(session.id))),
                  _metric('Nakit hareketi', money(pos.cashMovementsForSession(session.id))),
                  _metric('Beklenen nakit', money(pos.expectedRegisterCash(session))),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(onPressed: () => _movement(context, 'Giriş'),
                      icon: const Icon(Icons.add), label: const Text('Para girişi')),
                    OutlinedButton.icon(onPressed: () => _movement(context, 'Çıxış'),
                      icon: const Icon(Icons.remove), label: const Text('Para çıkışı')),
                    FilledButton.icon(onPressed: () => _close(context, session),
                      icon: const Icon(Icons.lock), label: const Text('Vardiyayı kapat')),
                  ]),
                ]),
          )),
          const SizedBox(height: 12),
          const Text('Nakit hareketleri',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          if (session == null || !pos.cashMovements.any((m) => m.sessionId == session.id))
            const ListTile(title: Text('Aktif vardiyada nakit hareketi yok.')),
          if (session != null)
            for (final movement in pos.cashMovements.where((m) => m.sessionId == session.id).toList().reversed)
              ListTile(
                leading: Icon(movement.type == 'Giriş' ? Icons.call_received : Icons.call_made),
                title: Text('${movement.type}: ${money(movement.amount)}'),
                subtitle: Text('${movement.note} · ${bakuTimestamp(movement.at)}')),
          const Divider(),
          const Text('Önceki vardiyalar',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          if (sessions.isEmpty)
            const ListTile(title: Text('Henüz vardiya kaydı yok.')),
          for (final item in sessions)
            Card(child: ExpansionTile(
              title: Text('${bakuTimestamp(item.openedAt)} · ${item.isOpen ? 'Açık' : 'Kapalı'}'),
              subtitle: Text('Açılış ${money(item.openingCash)} · Nakit satış ${money(pos.cashSalesForSession(item.id))}'),
              children: [
                ListTile(title: const Text('Beklenen nakit'),
                  trailing: Text(money(item.expectedCash ?? pos.expectedRegisterCash(item)))),
                if (item.closingCash != null)
                  ListTile(title: const Text('Sayılan nakit'), trailing: Text(money(item.closingCash!))),
                if (item.closingCash != null && item.expectedCash != null)
                  ListTile(title: const Text('Kasa farkı'),
                    trailing: Text(money(item.closingCash! - item.expectedCash!))),
                for (final movement in pos.cashMovements.where((m) => m.sessionId == item.id))
                  ListTile(dense: true,
                    title: Text('${movement.type}: ${money(movement.amount)}'),
                    subtitle: Text(movement.note)),
              ],
            )),
        ]),
      );
    },
  );
}


class SuppliersPage extends StatefulWidget {
  const SuppliersPage({super.key});
  @override State<SuppliersPage> createState() => _SuppliersPageState();
}
class _SuppliersPageState extends State<SuppliersPage> {
  Future<void> _addSupplier() async {
    final name=TextEditingController(), phone=TextEditingController(), notes=TextEditingController();
    final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('Tedarikçi ekle'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:name,decoration:const InputDecoration(labelText:'Firma / kişi adı')),
      TextField(controller:phone,decoration:const InputDecoration(labelText:'Telefon')),
      TextField(controller:notes,decoration:const InputDecoration(labelText:'Not'),maxLines:2),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Kaydet'))]));
    if(ok==true) {
      final saved=pos.addSupplier(SupplierRecord(id:DateTime.now().microsecondsSinceEpoch.toString(),name:name.text.trim(),phone:phone.text.trim(),notes:notes.text.trim()));
      if(!saved&&mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Tedarikçi adı boş veya zaten kayıtlı.')));
    }
    name.dispose();phone.dispose();notes.dispose();
  }
  Future<void> _purchase() async {
    if(pos.suppliers.where((s)=>s.active).isEmpty||pos.products.where((p)=>p.active).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Önce en az bir aktif tedarikçi ve ürün ekleyin.'))); return;
    }
    String supplierId=pos.suppliers.firstWhere((s)=>s.active).id;
    String productId=pos.products.firstWhere((p)=>p.active).id;
    final quantity=TextEditingController(text:'1'), cost=TextEditingController();
    final ok=await showDialog<bool>(context:context,builder:(c)=>StatefulBuilder(builder:(c,set)=>AlertDialog(title:const Text('Mal alımı kaydet'),content:Column(mainAxisSize:MainAxisSize.min,children:[
      DropdownButtonFormField<String>(initialValue:supplierId,decoration:const InputDecoration(labelText:'Tedarikçi'),items:pos.suppliers.where((x)=>x.active).map((x)=>DropdownMenuItem(value:x.id,child:Text(x.name))).toList(),onChanged:(v)=>set(()=>supplierId=v??supplierId)),
      DropdownButtonFormField<String>(initialValue:productId,decoration:const InputDecoration(labelText:'Ürün'),items:pos.products.where((x)=>x.active).map((x)=>DropdownMenuItem(value:x.id,child:Text(x.name))).toList(),onChanged:(v)=>set(()=>productId=v??productId)),
      TextField(controller:quantity,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Alınan adet')),
      TextField(controller:cost,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Birim alış maliyeti (₼)')),
    ]),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Stoka ekle'))])));
    if(ok==true) {
      final success=pos.recordPurchase(supplierId:supplierId,productId:productId,quantity:int.tryParse(quantity.text)??0,unitCost:parseMoney(cost.text) ?? 0);
      if(!success&&mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Mal alımı kaydedilemedi. Miktar ve maliyeti kontrol edin.')));
    }
    quantity.dispose();cost.dispose();
  }
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(context,_)=>Scaffold(
    appBar:AppBar(title:const Text('Tedarikçi ve satın alma'),actions:[IconButton(onPressed:_addSupplier,icon:const Icon(Icons.person_add)),IconButton(onPressed:_purchase,icon:const Icon(Icons.add_shopping_cart))]),
    body:ListView(padding:const EdgeInsets.all(12),children:[
      Row(children:[Expanded(child:Text('Tedarikçiler · ${pos.suppliers.length}',style:const TextStyle(fontWeight:FontWeight.bold,fontSize:18))),Text('Mal alımı: ${money(pos.purchases.fold<int>(0,(a,x)=>a+x.total))}')]),
      if(pos.suppliers.isEmpty) const ListTile(title:Text('Henüz tedarikçi yok.')),
      for(final supplier in pos.suppliers) Card(child:ListTile(leading:const Icon(Icons.local_shipping),title:Text(supplier.name),subtitle:Text('${supplier.phone} · ${supplier.notes}'),trailing:Text(pos.purchases.where((x)=>x.supplierId==supplier.id).length.toString()))),
      const Divider(),const Text('Son mal alımları',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
      if(pos.purchases.isEmpty) const ListTile(title:Text('Henüz mal alımı kaydedilmedi.')),
      for(final purchase in pos.purchases.reversed.take(100)) ListTile(title:Text('${purchase.productName} × ${purchase.quantity}'),subtitle:Text('${purchase.supplierName} · ${bakuTimestamp(purchase.at)} · Birim ${money(purchase.unitCost)}'),trailing:Text(money(purchase.total))),
    ]),
  ));
}

class CustomersReservationsPage extends StatefulWidget {
  const CustomersReservationsPage({super.key});
  @override State<CustomersReservationsPage> createState()=>_CustomersReservationsPageState();
}
class _CustomersReservationsPageState extends State<CustomersReservationsPage> {
  Future<void> _addCustomer() async {
    final name=TextEditingController(),phone=TextEditingController(),notes=TextEditingController();
    final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('Müşteri ekle'),content:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:name,decoration:const InputDecoration(labelText:'Ad soyad')),
      TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'Telefon')),
      TextField(controller:notes,decoration:const InputDecoration(labelText:'Not')),
    ]),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Kaydet'))]));
    if(ok==true&&!pos.addCustomer(CustomerRecord(id:DateTime.now().microsecondsSinceEpoch.toString(),name:name.text.trim(),phone:phone.text.trim(),notes:notes.text.trim()))&&mounted)
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Müşteri adı boş veya telefon numarası zaten kayıtlı.')));
    name.dispose();phone.dispose();notes.dispose();
  }
  Future<void> _addReservation() async {
    final name=TextEditingController(),phone=TextEditingController(),guests=TextEditingController(text:'2'),note=TextEditingController();
    int tableId=1; DateTime date=azWallTime(azNow()).add(const Duration(days:1)); TimeOfDay time=const TimeOfDay(hour:19,minute:0);
    final ok=await showDialog<bool>(context:context,builder:(c)=>StatefulBuilder(builder:(c,set)=>AlertDialog(title:const Text('Masa rezervasyonu'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:name,decoration:const InputDecoration(labelText:'Müşteri adı')),
      TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'Telefon')),
      DropdownButtonFormField<int>(initialValue:tableId,decoration:const InputDecoration(labelText:'Masa'),items:List.generate(kTableCount,(i)=>DropdownMenuItem(value:i+1,child:Text('Masa ${i+1}'))),onChanged:(v)=>set(()=>tableId=v??1)),
      TextField(controller:guests,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Kişi sayısı')),
      ListTile(contentPadding:EdgeInsets.zero,title:Text('Tarih: ${dayKey(date)}'),trailing:TextButton(onPressed:()async{final picked=await showDatePicker(context:c,initialDate:date.isBefore(azWallTime(azNow()))?azWallTime(azNow()):date,firstDate:azWallTime(azNow()),lastDate:azWallTime(azNow()).add(const Duration(days:365)));if(picked!=null)set(()=>date=picked);},child:const Text('Değiştir'))),
      ListTile(contentPadding:EdgeInsets.zero,title:Text('Saat: ${time.format(c)}'),trailing:TextButton(onPressed:()async{final picked=await showTimePicker(context:c,initialTime:time);if(picked!=null)set(()=>time=picked);},child:const Text('Değiştir'))),
      TextField(controller:note,decoration:const InputDecoration(labelText:'Not')),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Rezervasyon oluştur'))])));
    if(ok==true) {
      final when=DateTime(date.year,date.month,date.day,time.hour,time.minute);
      final saved=pos.addReservation(ReservationRecord(id:DateTime.now().microsecondsSinceEpoch.toString(),customerName:name.text.trim(),phone:phone.text.trim(),dateTime:bakuWallTimeToUtc(when).toIso8601String(),tableId:tableId,guests:int.tryParse(guests.text)??0,note:note.text.trim()));
      if(!saved&&mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Rezervasyon çakışıyor veya bilgiler geçersiz. Aynı masa için 2 saatlik aralık bırakın.')));
    }
    name.dispose();phone.dispose();guests.dispose();note.dispose();
  }
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(context,_)=>Scaffold(
    appBar:AppBar(title:const Text('Müşteri ve rezervasyon'),actions:[IconButton(onPressed:_addCustomer,icon:const Icon(Icons.person_add)),IconButton(onPressed:_addReservation,icon:const Icon(Icons.event_available))]),
    body:ListView(padding:const EdgeInsets.all(12),children:[
      Text('Müşteriler · ${pos.customers.length}',style:const TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
      if(pos.customers.isEmpty) const ListTile(title:Text('Henüz müşteri kaydı yok.')),
      for(final customer in pos.customers) ListTile(leading:const Icon(Icons.person),title:Text(customer.name),subtitle:Text('${customer.phone} · ${customer.notes}'),trailing:Text('${customer.visits} ziyaret')),
      const Divider(),const Text('Masa rezervasyonları',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
      if(pos.reservations.isEmpty) const ListTile(title:Text('Henüz rezervasyon yok.')),
      for(final item in pos.reservations.toList()..sort((a,b)=>a.dateTime.compareTo(b.dateTime)))
        Card(child:ListTile(title:Text('${item.customerName} · Masa ${item.tableId}'),subtitle:Text('${bakuTimestamp(item.dateTime)} · ${item.guests} kişi · ${item.phone}\n${item.note}'),isThreeLine:true,trailing:PopupMenuButton<String>(initialValue:item.status,onSelected:(v)=>pos.setReservationStatus(item,v),itemBuilder:(_)=>const [PopupMenuItem(value:'Bekliyor',child:Text('Bekliyor')),PopupMenuItem(value:'Geldi',child:Text('Geldi')),PopupMenuItem(value:'Tamamlandı',child:Text('Tamamlandı')),PopupMenuItem(value:'İptal',child:Text('İptal'))],child:Chip(label:Text(item.status))))),
    ]),
  ));
}

class AnalyticsPage extends StatelessWidget {
  const AnalyticsPage({super.key});
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(context,_) {
    final now=azWallTime(azNow()); final start=DateTime(now.year,now.month,now.day).subtract(const Duration(days:29));
    final sales=pos.sales.where((sale){final d=DateTime.tryParse(sale.date);return d!=null&&!d.isBefore(start);}).toList();
    final expenses=pos.expenses.where((expense){final d=DateTime.tryParse(expense.date);return d!=null&&!d.isBefore(start);}).toList();
    final revenue=sales.fold<int>(0,(a,x)=>a+x.total);
    final cost=sales.fold<int>(0,(a,x)=>a+pos.costOfSale(x));
    final expenseTotal=expenses.fold<int>(0,(a,x)=>a+x.amount);
    final productTotals=<String,int>{};
    for(final sale in sales){for(final item in sale.items){productTotals[item.name]=(productTotals[item.name]??0)+item.qty;}}
    final ranked=productTotals.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
    final daily=<String,int>{};
    for(final sale in sales){daily[sale.date]=(daily[sale.date]??0)+sale.total;}
    final days=daily.entries.toList()..sort((a,b)=>a.key.compareTo(b.key));
    final maxDaily=days.fold<int>(0,(a,x)=>x.value>a?x.value:a);
    return Scaffold(appBar:AppBar(title:const Text('Gelişmiş analiz · 30 gün')),body:ListView(padding:const EdgeInsets.all(12),children:[
      Wrap(spacing:8,runSpacing:8,children:[
        _metric('Ciro',money(revenue)),_metric('Ürün maliyeti',money(cost)),
        _metric('Brüt kâr',money(revenue-cost)),_metric('Gider',money(expenseTotal)),
        _metric('Net kâr',money(revenue-cost-expenseTotal)),_metric('Satış', '${sales.length}'),
      ]),
      const SizedBox(height:16),const Text('Günlük ciro',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
      if(days.isEmpty) const ListTile(title:Text('Bu dönemde satış bulunmuyor.')),
      for(final day in days) Padding(padding:const EdgeInsets.symmetric(vertical:5),child:Row(children:[
        SizedBox(width:92,child:Text(day.key)),
        Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(5),child:LinearProgressIndicator(value:maxDaily==0?0:day.value/maxDaily,minHeight:12))),
        const SizedBox(width:8),SizedBox(width:88,child:Text(money(day.value),textAlign:TextAlign.end)),
      ])),
      const Divider(),const Text('En çok satılan ürünler',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
      if(ranked.isEmpty) const ListTile(title:Text('Henüz ürün satılmadı.')),
      for(final item in ranked.take(10)) ListTile(title:Text(item.key),trailing:Text('${item.value} adet')),
      const Divider(),const Text('Ödeme dağılımı',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
      for(final method in ['Nakit','Kart']) ListTile(title:Text(method),trailing:Text(money(sales.expand((x)=>x.payments).where((x)=>x.method==method).fold<int>(0,(a,x)=>a+x.amount)))),
    ]));
  });
}

class BarcodePage extends StatefulWidget {
  const BarcodePage({super.key});
  @override State<BarcodePage> createState()=>_BarcodePageState();
}
class _BarcodePageState extends State<BarcodePage> {
  final code=TextEditingController(); String? message; Product? found; int tableId=1; String? productId;
  @override void dispose(){code.dispose();super.dispose();}
  void _scan(String value){final product=pos.productByBarcode(value);setState(() { found=product; message=product==null?'Barkod eşleşmesi bulunamadı.':'Bulundu: ${product.name} · ${money(product.price)}'; });}
  Future<void> _assign() async {
    if(productId==null)return;
    final product=pos.products.firstWhere((p)=>p.id==productId);
    if(!pos.setProductBarcode(product,code.text)) {setState(()=>message='Barkod başka ürüne atanmış veya kayıt edilemedi.');return;}
    setState(()=>message='Barkod ${product.name} ürününe kaydedildi.');
  }
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(context,_)=>Scaffold(
    appBar:AppBar(title:const Text('Barkod okuyucu')),body:ListView(padding:const EdgeInsets.all(16),children:[
      const Text('USB veya Bluetooth barkod okuyucu klavye gibi çalışır. Alanı seçip barkodu okutun; cihaz Enter gönderdiğinde ürün bulunur.',style:TextStyle(fontSize:14)),
      TextField(controller:code,autofocus:true,decoration:const InputDecoration(labelText:'Barkod / ürün kodu',prefixIcon:Icon(Icons.qr_code_scanner)),onSubmitted:_scan),
      const SizedBox(height:8),FilledButton.icon(onPressed:()=>_scan(code.text),icon:const Icon(Icons.search),label:const Text('Barkodu bul')),
      if(message!=null) Padding(padding:const EdgeInsets.all(12),child:Text(message!,style:TextStyle(color:found==null?red:green))),
      if(found!=null) Card(child:ListTile(title:Text(found!.name),subtitle:Text('Stok: ${found!.stock} · ${money(found!.price)}'),trailing:FilledButton(onPressed:()=>pos.add(pos.tables[tableId-1],found!)?ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Ürün masaya eklendi.'))):ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Ürün eklenemedi; masa veya stok durumunu kontrol edin.'))),child:const Text('Masaya ekle')))),
      DropdownButtonFormField<int>(initialValue:tableId,decoration:const InputDecoration(labelText:'Sipariş eklenecek masa'),items:List.generate(kTableCount,(i)=>DropdownMenuItem(value:i+1,child:Text('Masa ${i+1}'))),onChanged:(v)=>setState(()=>tableId=v??1)),
      const Divider(),const Text('Ürüne barkod ata',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
      DropdownButtonFormField<String>(initialValue:productId,decoration:const InputDecoration(labelText:'Ürün seç'),items:pos.products.map((p)=>DropdownMenuItem(value:p.id,child:Text(p.name))).toList(),onChanged:(v)=>setState(()=>productId=v)),
      OutlinedButton.icon(onPressed:productId==null?null:_assign,icon:const Icon(Icons.link),label:const Text('Barkodu ürüne kaydet')),
      for(final product in pos.products.where((p)=>pos.productBarcodes.containsKey(p.id))) ListTile(dense:true,title:Text(product.name),trailing:Text(pos.productBarcodes[product.id]!)),
    ]),
  ));
}
