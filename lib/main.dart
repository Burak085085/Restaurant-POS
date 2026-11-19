// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'storage.dart';

final GlobalKey<ScaffoldMessengerState> appMessengerKey = GlobalKey<ScaffoldMessengerState>();
const int kTableCount = 20;
const String kStoreKey = 'restaurant_pos_v2';
const Color ink = Color(0xFF1B2733), bg = Color(0xFFEEF1F4), green = Color(0xFF23845B), red = Color(0xFFC7443B), amber = Color(0xFFE39A1C);
String money(int cents) => '${cents ~/ 100},${(cents % 100).toString().padLeft(2, '0')} ₼';
int parseMoney(String s) { final value = double.tryParse(s.replaceAll(',', '.')); if (value == null || !value.isFinite || value <= 0 || value > 10000000) return 0; return (value * 100).round(); }
DateTime azNow() => DateTime.now().toUtc().add(const Duration(hours: 4));
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
class Sale { String date,time,staff; int table,total,discount; List<OrderLine> items; List<PaymentPart> payments; int? registerSessionId; Sale(this.date,this.time,this.staff,this.table,this.total,this.discount,this.items,this.payments,{this.registerSessionId}); Map<String,dynamic> toJson()=>{'date':date,'time':time,'staff':staff,'table':table,'total':total,'discount':discount,'registerSessionId':registerSessionId,'items':items.map((e)=>e.toJson()).toList(),'payments':payments.map((e)=>e.toJson()).toList()}; factory Sale.fromJson(Map<String,dynamic> j)=>Sale(j['date']??'',j['time']??'',j['staff']??'Admin',j['table']??0,j['total']??0,j['discount']??0,(j['items'] as List? ?? []).map((e)=>OrderLine.fromJson(Map<String,dynamic>.from(e))).toList(),(j['payments'] as List? ?? []).map((e)=>PaymentPart(e['method']??'Nakit',e['amount']??0,tendered:e['tendered']??e['amount']??0)).toList(),registerSessionId:j['registerSessionId']); }
class Expense { final int id,amount; final String date,category,note; Expense({required this.id,required this.amount,required this.date,required this.category,required this.note}); Map<String,dynamic> toJson()=>{'id':id,'amount':amount,'date':date,'category':category,'note':note}; factory Expense.fromJson(Map<String,dynamic> j)=>Expense(id:j['id']??0,amount:j['amount']??0,date:j['date']??'',category:j['category']??'Diğer',note:j['note']??''); }
class StockMovement { final int id,quantity,beforeStock,afterStock,productCost; final String productId,productName,type,at,note; StockMovement({required this.id,required this.productId,required this.productName,required this.type,required this.quantity,required this.beforeStock,required this.afterStock,required this.productCost,required this.at,required this.note}); Map<String,dynamic> toJson()=>{'id':id,'productId':productId,'productName':productName,'type':type,'quantity':quantity,'beforeStock':beforeStock,'afterStock':afterStock,'productCost':productCost,'at':at,'note':note}; factory StockMovement.fromJson(Map<String,dynamic> j)=>StockMovement(id:j['id']??0,productId:j['productId']??'',productName:j['productName']??'',type:j['type']??'',quantity:j['quantity']??0,beforeStock:j['beforeStock']??0,afterStock:j['afterStock']??0,productCost:j['productCost']??0,at:j['at']??'',note:j['note']??''); }
class Staff {
  String name, role, salt, pinHash;
  bool active;
  Staff(this.name, this.role, {String pin='1234', String? salt, String? pinHash, this.active=true})
      : salt = salt ?? _newPinSalt(),
        pinHash = pinHash ?? '' {
    if (pinHash == null) this.pinHash = _hashPin(this.salt, pin);
  }
  Staff._(this.name, this.role, this.salt, this.pinHash, this.active);
  static String _newPinSalt() { final random=math.Random.secure(); return List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2,'0')).join(); }
  static String _hashPin(String salt, String pin) => sha256.convert(utf8.encode('$salt:$pin')).toString();
  void setPin(String pin) { salt=_newPinSalt(); pinHash=_hashPin(salt,pin); }
  bool verifyPin(String candidate) => pinHash == _hashPin(salt, candidate);
  Map<String,dynamic> toJson()=>{'name':name,'role':role,'salt':salt,'pinHash':pinHash,'active':active};
  factory Staff.fromJson(Map<String,dynamic> j) {
    final name = j['name'] ?? 'Personel';
    final role = j['role'] ?? 'Garson';
    final salt = j['salt']?.toString();
    final hash = j['pinHash']?.toString();
    if (salt != null && hash != null) return Staff._(name, role, salt, hash, j['active'] ?? true);
    return Staff(name, role, pin: (j['pin'] ?? '1234').toString(), active: j['active'] ?? true);
  }
}
class Audit { String at,user,action,detail; Audit(this.at,this.user,this.action,this.detail); Map<String,dynamic> toJson()=>{'at':at,'user':user,'action':action,'detail':detail}; factory Audit.fromJson(Map<String,dynamic> j)=>Audit(j['at']??'',j['user']??'',j['action']??'',j['detail']??''); }

class Pos extends ChangeNotifier {
  List<Product> products=[Product('p1','Dönerler','Tavuk döner',300),Product('p2','Dönerler','Dana döner',500),Product('p3','Dönerler','Dürüm döner',400),Product('p4','Dönerler','Porsiyon döner',700),Product('p5','İçecekler','Kola',200),Product('p6','İçecekler','Fanta',200),Product('p7','İçecekler','Ayran',100),Product('p8','İçecekler','Su',50),Product('p9','Ekstra','Patates',200),Product('p10','Ekstra','Ketçap',50),Product('p11','Ekstra','Mayonez',50)];
  List<PosTable> tables=List.generate(kTableCount,(i)=>PosTable(i+1)); List<Sale> sales=[]; List<RegisterSession> registerSessions=[]; List<CashMovement> cashMovements=[]; List<Expense> expenses=[]; List<StockMovement> stockMovements=[]; List<Ingredient> ingredients=[]; Map<String,List<RecipeLine>> recipes={}; List<Staff> staff=[Staff('Admin','Yönetici')]; List<Audit> audit=[]; String currentUser='Admin'; final StoreRepository _repository; Future<void> _queue=Future.value();
  Pos({StoreRepository? repository}) : _repository = repository ?? SqliteStoreRepository();
  Future<void> load() async { final raw=await _repository.read(); if(raw==null)return; try { final j=jsonDecode(raw) as Map<String,dynamic>; products=(j['products'] as List? ?? []).map((e)=>Product.fromJson(Map<String,dynamic>.from(e))).toList(); tables=List.generate(kTableCount,(i)=>PosTable(i+1)); for(final x in (j['tables'] as List? ?? [])){final m=Map<String,dynamic>.from(x); final id=m['id'] as int; if(id<1||id>kTableCount)continue; final t=tables[id-1]; t.items=(m['items'] as List? ?? []).map((e)=>OrderLine.fromJson(Map<String,dynamic>.from(e))).toList(); t.kitchen=KitchenState.values[(m['kitchen']??0).clamp(0,3).toInt()]; final rawItems=(m['items'] as List? ?? []); for(var lineIndex=0;lineIndex<t.items.length;lineIndex++){final rawLine=Map<String,dynamic>.from(rawItems[lineIndex]);if(!rawLine.containsKey('kitchen'))t.items[lineIndex].kitchen=t.kitchen;} t.discount=m['discount']??0;t.discountPercent=m['discountPercent']??false;t.discountReason=m['discountReason']??'';} sales=(j['sales'] as List? ?? []).map((e)=>Sale.fromJson(Map<String,dynamic>.from(e))).toList(); expenses=(j['expenses'] as List? ?? []).map((e)=>Expense.fromJson(Map<String,dynamic>.from(e))).toList(); stockMovements=(j['stockMovements'] as List? ?? []).map((e)=>StockMovement.fromJson(Map<String,dynamic>.from(e))).toList(); ingredients=(j['ingredients'] as List? ?? []).map((e)=>Ingredient.fromJson(Map<String,dynamic>.from(e))).toList(); recipes=(j['recipes'] as Map? ?? {}).map((key,value)=>(key.toString(),(value as List).map((e)=>RecipeLine.fromJson(Map<String,dynamic>.from(e))).toList())); registerSessions=(j['registerSessions'] as List? ?? []).map((e)=>RegisterSession.fromJson(Map<String,dynamic>.from(e))).toList(); cashMovements=(j['cashMovements'] as List? ?? []).map((e)=>CashMovement.fromJson(Map<String,dynamic>.from(e))).toList(); final legacyStaff=(j['staff'] as List? ?? []).map((e)=>Staff.fromJson(Map<String,dynamic>.from(e))).toList(); final admins=legacyStaff.where((member)=>member.name=='Admin').toList(); final admin=admins.isNotEmpty ? admins.first : Staff('Admin','Yönetici'); admin.active=true; staff=[admin]; audit=(j['audit'] as List? ?? []).map((e)=>Audit.fromJson(Map<String,dynamic>.from(e))).toList(); currentUser='Admin'; } catch (_) { await _repository.backupCorrupt(raw); products=[Product('p1','Dönerler','Tavuk döner',300),Product('p2','Dönerler','Dana döner',500),Product('p3','Dönerler','Dürüm döner',400),Product('p4','Dönerler','Porsiyon döner',700),Product('p5','İçecekler','Kola',200),Product('p6','İçecekler','Fanta',200),Product('p7','İçecekler','Ayran',100),Product('p8','İçecekler','Su',50),Product('p9','Ekstra','Patates',200),Product('p10','Ekstra','Ketçap',50),Product('p11','Ekstra','Mayonez',50)]; tables=List.generate(kTableCount,(i)=>PosTable(i+1)); sales=[]; registerSessions=[]; cashMovements=[]; expenses=[]; stockMovements=[]; staff=[Staff('Admin','Yönetici')]; audit=[]; currentUser='Admin'; } }

  String _snapshot() => jsonEncode({
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
    'audit': audit.map((e) => e.toJson()).toList(),
    'currentUser': currentUser,
  });

  Future<List<BackupFile>> listBackups() => _repository.listBackups();
  Future<String?> readBackup(String name) => _repository.readBackup(name);

  Future<bool> restoreBackup(String payload) async {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return false;
      for (final key in ['products', 'tables', 'sales']) {
        if (decoded[key] is! List) return false;
      }
      final candidateRepository = MemoryStoreRepository(value: payload);
      final candidate = Pos(repository: candidateRepository);
      await candidate.load();
      if (candidateRepository.corruptBackup != null) return false;

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

  Future<void> flush()=>_queue;
  void save() {
    final snapshot = jsonEncode({
      'products': products.map((e) => e.toJson()).toList(),
      'tables': tables.map((e) => e.toJson()).toList(),
      'sales': sales.map((e) => e.toJson()).toList(),
      'expenses': expenses.map((e) => e.toJson()).toList(),
      'stockMovements': stockMovements.map((e) => e.toJson()).toList(),
      'registerSessions': registerSessions.map((e) => e.toJson()).toList(),
      'cashMovements': cashMovements.map((e) => e.toJson()).toList(),
      'staff': staff.map((e) => e.toJson()).toList(),
      'audit': audit.map((e) => e.toJson()).toList(),
      'currentUser': currentUser,
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
  void log(String action,String detail){audit.insert(0,Audit(stamp(azNow()),currentUser,action,detail)); if(audit.length>2000)audit.removeRange(2000,audit.length);}
  bool can(String permission) => currentUser == 'Admin' && staff.any((member) => member.name == 'Admin' && member.active);
  int get todayTotal=>sales.where((s)=>s.date==dayKey(azNow())).fold(0,(a,s)=>a+s.total); int get todayCount=>sales.where((s)=>s.date==dayKey(azNow())).length;
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

  bool add(PosTable t, Product p) {
    if (!can('orders') || !p.active || reservedStock(p.id) >= p.stock || !recipeAvailable(p)) return false;
    final existing = t.items.where((line) => line.productId == p.id && !line.sent);
    if (existing.isNotEmpty) { existing.first.qty++; } else { t.items.add(OrderLine(p.id, p.name, p.price, 1)); }
    log('Sipariş', 'Masa ${t.id}: ${p.name} eklendi'); save(); return true;
  }
  bool qty(PosTable t, int i, int delta) {
    if (!can('orders') || i < 0 || i >= t.items.length) return false;
    final line = t.items[i]; final product = products.where((p) => p.id == line.productId);
    if (delta > 0 && (product.isEmpty || reservedStock(line.productId) >= product.first.stock || !recipeAvailable(product.first))) return false;
    if (delta < 0 && line.sent) return false;
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
    if (!can('orders') || source == destination || source.items.isEmpty ||
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
    if (!can('orders') || source == destination || source.items.isEmpty ||
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
    if (!can('orders') || source == destination || source.items.isEmpty ||
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
  bool stockChange(Product p, int delta, {String note='Manuel stok düzeltmesi'}) { if(!can('inventory')||delta==0||note.trim().isEmpty)return false;final before=p.stock;final next=(before+delta).clamp(0,1000000).toInt();if(next<reservedStock(p.id)||next==before)return false;p.stock=next;stockMovements.add(StockMovement(id:DateTime.now().microsecondsSinceEpoch,productId:p.id,productName:p.name,type:delta>0?'Giriş':'Çıkış',quantity:delta.abs(),beforeStock:before,afterStock:next,productCost:p.costPrice,at:azNow().toIso8601String(),note:note.trim()));log('Stok','${p.name}: $before → $next · ${note.trim()}');save();return true;}
  bool addExpense(int amount,String category,String note){if(!can('reports')||amount<=0||category.trim().isEmpty||note.trim().isEmpty)return false;expenses.add(Expense(id:DateTime.now().microsecondsSinceEpoch,amount:amount,category:category.trim(),note:note.trim(),date:dayKey(azNow())));log('Gider','${category.trim()} · ${money(amount)} · ${note.trim()}');save();return true;}
  int costOfSale(Sale sale)=>sale.items.fold(0,(s,item)=>s+item.unitCost*item.qty);int get totalExpenses=>expenses.fold(0,(s,e)=>s+e.amount);int get totalCostOfSales=>sales.fold(0,(s,e)=>s+costOfSale(e));int get netProfit=>sales.fold(0,(s,e)=>s+e.total-costOfSale(e))-totalExpenses;
  String buildCsv(){String q(Object? v)=>'"${v.toString().replaceAll('"','""')}"';final b=StringBuffer('Tarih;Tür;Açıklama;Adet;Ciro/Gider;Maliyet\\r\\n');for(final sale in sales){b.writeln([q(sale.date),q('Satış'),q('Masa ${sale.table}'),q(sale.items.fold<int>(0,(int n,OrderLine x)=>n+x.qty)),q(sale.total/100),q(costOfSale(sale)/100)].join(';'));}for(final e in expenses){b.writeln([q(e.date),q('Gider'),q('${e.category}: ${e.note}'),q(1),q(e.amount/100),q(0)].join(';'));}return b.toString();}
  bool checkout(PosTable t, List<PaymentPart> payments) {
    if (!can('orders') || t.items.isEmpty || t.items.any((line) => !line.sent)) return false;
    final total = t.total;
    if (payments.isEmpty || payments.any((part) => !part.isValid) || payments.fold(0, (sum, part) => sum + part.amount) != total) return false;
    final ingredientNeeds = <String, int>{};
    for (final line in t.items) {
      final matches = products.where((product) => product.id == line.productId);
      if (matches.isEmpty || matches.first.stock < line.qty) return false;
      for (final recipeLine in recipes[line.productId] ?? const <RecipeLine>[]) {
        ingredientNeeds[recipeLine.ingredientId] =
            (ingredientNeeds[recipeLine.ingredientId] ?? 0) + recipeLine.quantity * line.qty;
      }
    }
    for (final entry in ingredientNeeds.entries) {
      final ingredient = ingredients.where((item) => item.id == entry.key);
      if (ingredient.isEmpty || ingredient.first.stock < entry.value) return false;
    }
    final now = azNow();
    for (final line in t.items) {
      final product = products.firstWhere((item) => item.id == line.productId);
      final before = product.stock;
      product.stock -= line.qty;
      stockMovements.add(StockMovement(id: DateTime.now().microsecondsSinceEpoch,
        productId: product.id, productName: product.name, type: 'Satış',
        quantity: line.qty, beforeStock: before, afterStock: product.stock,
        productCost: product.costPrice, at: now.toIso8601String(),
        note: 'Masa ${t.id} satışı'));
    }
    for (final entry in ingredientNeeds.entries) {
      final ingredient = ingredients.firstWhere((item) => item.id == entry.key);
      ingredient.stock -= entry.value;
    }
    sales.add(Sale(dayKey(now), stamp(now), currentUser, t.id, total, t.subtotal-total,
      t.items.map((e) { final product=products.firstWhere((p)=>p.id==e.productId); return OrderLine(e.productId,e.name,e.price,e.qty,unitCost:product.costPrice + recipeCost(product)); }).toList(), payments,
      registerSessionId: activeRegister?.id));
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
  bool setStaffActive(Staff member, bool active) {
    if (!can('staff') || (member.name == currentUser && !active)) return false;
    member.active = active; log('Personel', '${member.name}: ${active ? 'aktif' : 'pasif'}'); save(); return true;
  }
  int get lowStock=>products.where((p)=>p.active&&p.stock<=p.lowAt).length;
}
final pos=Pos();
Future<void> main() async {WidgetsFlutterBinding.ensureInitialized();await pos.load();runApp(const PosApp());}
class PosLogo extends StatelessWidget { final double size; const PosLogo({super.key, this.size = 112}); @override Widget build(BuildContext context) => SvgPicture.asset('assets/branding/restoram_logo.svg', width: size, height: size, fit: BoxFit.contain); }
class PosApp extends StatelessWidget {const PosApp({super.key});@override Widget build(BuildContext context)=>MaterialApp(scaffoldMessengerKey:appMessengerKey,title:'Restaurant POS',debugShowCheckedModeBanner:false,theme:ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:ink),scaffoldBackgroundColor:bg,appBarTheme:const AppBarTheme(backgroundColor:ink,foregroundColor:Colors.white)),home:const Home());}

class Home extends StatefulWidget {const Home({super.key});@override State<Home> createState()=>_HomeState();}
class _HomeState extends State<Home>{int tab=0;bool authenticated=false;@override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(context,_){if(!authenticated)return PinGate(onAuthenticated:()=>setState(()=>authenticated=true));final pages=[const TablesPage(),const KitchenPage(),const InventoryPage(),const ReportsPage(),const AdminPage()];return Scaffold(body:SafeArea(child:pages[tab]),bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v),destinations:const [NavigationDestination(icon:Icon(Icons.table_restaurant),label:'Masalar'),NavigationDestination(icon:Icon(Icons.soup_kitchen),label:'Mutfak'),NavigationDestination(icon:Icon(Icons.inventory_2),label:'Stok'),NavigationDestination(icon:Icon(Icons.bar_chart),label:'Rapor'),NavigationDestination(icon:Icon(Icons.settings),label:'Yönetim') ]));});}

class TablesPage extends StatelessWidget {
  const TablesPage({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pos,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Restaurant POS'),
        leading: const Padding(padding: EdgeInsets.all(6), child: PosLogo(size: 40)),
        actions: [Padding(padding: const EdgeInsets.all(12),
          child: Center(child: Text(pos.currentUser)))]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 16, children: [
          Text('Tarih: ${stamp(azNow())}'),
          if (pos.can('reports')) Text('Bugünkü ciro: ${money(pos.todayTotal)}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('Düşük stok: ${pos.lowStock}'),
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
                onLongPress: () => showDialog<void>(context: c,
                  builder: (_) => TableOperationsDialog(source: t)),
                child: Padding(padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Row(children: [
                        Expanded(child: Text('Masa ${t.id}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17))),
                        const Icon(Icons.swap_horiz, size: 18, color: Colors.black45),
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
            value: mode,
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
            value: targetId,
            decoration: const InputDecoration(labelText: 'Hedef masa'),
            items: targets.map((table) => DropdownMenuItem(
              value: table.id, child: Text('Masa ${table.id}'))).toList(),
            onChanged: (value) => setState(() => targetId = value),
          ),
          if (mode == 'Böl') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: lineIndex,
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
Widget _products(List<Product> list)=>GridView.builder(padding:const EdgeInsets.all(10),gridDelegate:const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent:170,childAspectRatio:1.45,crossAxisSpacing:8,mainAxisSpacing:8),itemCount:list.length,itemBuilder:(c,i){final p=list[i];return Card(child:InkWell(onTap:p.stock>0&&pos.can('orders')?(){if(!pos.add(t,p)){ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('Yeterli stok yok veya işlem yetkiniz bulunmuyor.')));}}:null,child:Padding(padding:const EdgeInsets.all(10),child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text(p.name,style:const TextStyle(fontWeight:FontWeight.bold)),Text(money(p.price)),Text('Stok: ${p.stock}',style:TextStyle(color:p.stock<=p.lowAt?red:Colors.black54))]))));});
Widget _ticket()=>Container(color:Colors.white,child:Column(children:[Padding(padding:const EdgeInsets.all(12),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('Sipariş',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),Text('Mutfak: ${kitchenLabel(t)}') ])),Expanded(child:ListView.builder(itemCount:t.items.length,itemBuilder:(c,i){final x=t.items[i];return ListTile(title:Text(x.name),subtitle:Text('${money(x.price)} × ${x.qty}'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(onPressed:pos.can('orders')&&!x.sent?()=>pos.qty(t,i,-1):null,icon:const Icon(Icons.remove)),IconButton(onPressed:pos.can('orders')?(){if(!pos.qty(t,i,1)){ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text(x.sent?'Mutfağa gönderilen ürünün miktarı değiştirilemez. Yeni ürün satırı ekleyin.':'Stok yetersiz.')));}}:null,icon:const Icon(Icons.add))]));})),Padding(padding:const EdgeInsets.all(12),child:Column(children:[Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('Ara toplam'),Text(money(t.subtotal))]),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('İndirim'),Text(money(t.subtotal-t.total))]),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('TOPLAM',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),Text(money(t.total),style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold))]),Wrap(spacing:8,children:[OutlinedButton.icon(onPressed:t.items.isEmpty||!pos.can('discount')?null:()=>_discount(context),icon:const Icon(Icons.percent),label:const Text('İndirim')),if(t.discount>0) OutlinedButton(onPressed:()=>pos.clearDiscount(t),child:const Text('İndirimi kaldır')),OutlinedButton(onPressed:!t.items.any((item)=>!item.sent)||!pos.can('orders')?null:()=>pos.sendKitchen(t),child:Text(t.items.any((item)=>!item.sent)?'Mutfağa gönder':'Gönderilecek yeni ürün yok'))]),SizedBox(width:double.infinity,child:FilledButton(onPressed:t.items.isEmpty||t.items.any((item)=>!item.sent)||!pos.can('orders')?null:()=>_pay(context),child:Text(t.items.any((item)=>!item.sent)?'Önce mutfağa gönder':'Ödeme al')))]))]));
Future<void> _discount(BuildContext context)async{final value=TextEditingController(text:t.discountPercent?t.discount.toString():(t.discount/100).toStringAsFixed(2));final reason=TextEditingController(text:t.discountReason);bool percent=t.discountPercent;final ok=await showDialog<bool>(context:context,builder:(c)=>StatefulBuilder(builder:(c,set)=>AlertDialog(title:const Text('İndirim tanımla'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:value,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'İndirim tutarı / yüzde')),SwitchListTile(title:const Text('Yüzde olarak uygula'),value:percent,onChanged:(v)=>set(()=>percent=v)),TextField(controller:reason,decoration:const InputDecoration(labelText:'İndirim nedeni'))]),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Vazgeç')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Uygula'))])));if(!context.mounted)return;if(ok==true){final n=percent?(int.tryParse(value.text)??0):parseMoney(value.text);if(!pos.setDiscount(t,n,percent,reason.text)){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('İndirim için geçerli bir tutar ve neden girin.')));}}}
Future<void> _pay(BuildContext context) async {
  final payments = await showDialog<List<PaymentPart>>(
    context: context,
    builder: (_) => PaymentDialog(total: t.total),
  );
  if (!context.mounted || payments == null) return;
  if (pos.checkout(t, payments)) {
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
  if (received <= 0) return null;
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

class PaymentDialog extends StatefulWidget {
  final int total;
  const PaymentDialog({super.key, required this.total});

  @override
  State<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<PaymentDialog> {
  final amount = TextEditingController();
  final parts = <PaymentPart>[];
  late int remaining = widget.total;

  @override
  void dispose() {
    amount.dispose();
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
        onPressed: remaining == 0 ? () => Navigator.pop(context, parts) : null,
        child: const Text('Ödemeyi tamamla'),
      ),
    ],
  );
}

class KitchenPage extends StatelessWidget {
  const KitchenPage({super.key});

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
      final activeTables = pos.tables.where((table) =>
        table.items.any((item) => item.sent && item.kitchen != KitchenState.served)).toList();
      return Scaffold(
        appBar: AppBar(title: const Text('Mutfak sipariş kuyruğu')),
        body: activeTables.isEmpty
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
            ),
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
    if (ok == true && name.text.trim().isNotEmpty && parsedPrice > 0) {
      pos.upsertProduct(Product(
        old?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        category.text.trim().isEmpty ? 'Genel' : category.text.trim(),
        name.text.trim(),
        parsedPrice,
        costPrice: parseMoney(cost.text),
        stock: (int.tryParse(stock.text) ?? 0).clamp(0, 1000000).toInt(),
        lowAt: (int.tryParse(low.text) ?? 5).clamp(0, 1000000).toInt(),
      ));
    }
  }
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
  Future<void> _addExpense(BuildContext context) async {final amount=TextEditingController(),category=TextEditingController(text:'Diğer'),note=TextEditingController();final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('İşletme gideri ekle'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Tutar (₼)')),TextField(controller:category,decoration:const InputDecoration(labelText:'Kategori')),TextField(controller:note,decoration:const InputDecoration(labelText:'Açıklama'))]),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Kaydet'))]));if(ok==true&&!pos.addExpense(parseMoney(amount.text),category.text,note.text)&&context.mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Gider kaydedilemedi.')));amount.dispose();category.dispose();note.dispose();}
  Future<void> _exportCsv(BuildContext context) async {try{final dir=await getApplicationDocumentsDirectory();final file=File('${dir.path}/restoram-rapor-${dayKey(azNow())}.csv');await file.writeAsString(pos.buildCsv(),flush:true);if(context.mounted)showDialog<void>(context:context,builder:(c)=>AlertDialog(title:const Text('CSV raporu hazır'),content:SelectableText(file.path),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Kapat'))]));}catch(e){if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('CSV oluşturulamadı: $e')));}}
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pos,
    builder: (context, _) {
      final today = dayKey(azNow());
      final todaySales = pos.sales.where((sale) => sale.date == today).toList();
      final weekStart = azNow().subtract(const Duration(days: 6));
      final weekSales = pos.sales.where((sale) {
        final date = DateTime.tryParse(sale.date);
        return date != null && !date.isBefore(DateTime(weekStart.year, weekStart.month, weekStart.day));
      }).toList();
      final cash = todaySales.fold(0, (sum, sale) => sum + sale.payments.where((part) => part.method == 'Nakit').fold(0, (value, part) => value + part.amount));
      final card = todaySales.fold(0, (sum, sale) => sum + sale.payments.where((part) => part.method == 'Kart').fold(0, (value, part) => value + part.amount));
      final units = weekSales.expand((sale) => sale.items).fold(0, (sum, item) => sum + item.qty);
      final productTotals = <String, int>{};
      for (final sale in weekSales) { for (final item in sale.items) { productTotals[item.name] = (productTotals[item.name] ?? 0) + item.qty; } }
      final topProducts = productTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      final todayExpenses=pos.expenses.where((e)=>e.date==today).toList();
      final weekExpenses=pos.expenses.where((e){final d=DateTime.tryParse(e.date);return d!=null&&!d.isBefore(DateTime(weekStart.year,weekStart.month,weekStart.day));}).toList();
      final monthStart=DateTime(azNow().year,azNow().month,1);
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
            _metric('Satış adedi', '${todaySales.length}'), _metric('Nakit', money(cash)), _metric('Kart', money(card)),
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
              title: Text('${stamp(DateTime.parse(shift.openedAt).toLocal())} · ${shift.isOpen ? 'Açık' : 'Kapalı'}'),
              subtitle: Text('Açılış ${money(shift.openingCash)} · Beklenen ${money(shift.expectedCash ?? pos.expectedRegisterCash(shift))}'),
              trailing: shift.closingCash == null || shift.expectedCash == null
                ? null : Text('Fark ${money(shift.closingCash! - shift.expectedCash!)}'),
            )),
          const Divider(),
          const Text('Kârlılık raporları',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),profitCard('Bugün',todaySales,todayExpenses),profitCard('Son 7 gün',weekSales,weekExpenses),profitCard('Bu ay',monthSales,monthExpenses),OutlinedButton.icon(onPressed:()=>_addExpense(context),icon:const Icon(Icons.add_card),label:const Text('İşletme gideri ekle')),OutlinedButton.icon(onPressed:()=>_exportCsv(context),icon:const Icon(Icons.download),label:const Text('Raporları CSV dışa aktar')),for(final expense in pos.expenses.reversed.take(30))ListTile(dense:true,title:Text('${expense.category} · ${money(expense.amount)}'),subtitle:Text('${expense.date} · ${expense.note}')),const Text('Satış geçmişi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          for (final sale in pos.sales.reversed) Card(child: ExpansionTile(
            title: Text('${sale.date} · ${sale.time} · Masa ${sale.table} · ${money(sale.total)}'),
            subtitle: Text('İndirim: ${money(sale.discount)}'),
            children: [
              for (final item in sale.items) ListTile(dense: true, title: Text('${item.qty} × ${item.name}'), trailing: Text(money(item.qty * item.price))),
              Padding(padding: const EdgeInsets.all(12), child: Text('Ödeme: ${sale.payments.map((part) => part.method == 'Nakit' ? 'Nakit ${money(part.amount)} (alınan ${money(part.tendered)}, para üstü ${money(part.change)})' : 'Kart ${money(part.amount)}').join(' + ')}')),
            ],
          )),
        ]) : const Center(child: Text('Raporlar için yönetici girişi gerekir.')),
      );
    },
  );
}

Widget _metric(String title,String value)=>SizedBox(width:160,child:Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title),Text(value,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:19))]))));

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pos,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Yönetim ve güvenlik')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const Card(child: ListTile(leading: Icon(Icons.admin_panel_settings), title: Text('Tek kullanıcı: Yönetici'), subtitle: Text('Personel hesabı ve kullanıcı değiştirme kapalıdır.'))),
        OutlinedButton.icon(onPressed: () => _changePin(context), icon: const Icon(Icons.lock_reset), label: const Text('Yönetici PIN kodunu değiştir')),
        OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupManagerPage())), icon: const Icon(Icons.restore), label: const Text('Yedekleri görüntüle ve geri yükle')),
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
      final valid = admin.verifyPin(oldPin.text.trim()) && RegExp(r'^[0-9]{4}$').hasMatch(value) && value != '1234' && value == confirmPin.text.trim();
      if (valid) { admin.setPin(value); pos.log('Güvenlik', 'Yönetici PIN kodu değiştirildi'); pos.save(); }
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
    appBar: AppBar(title: const Text('Yedekler')),
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
              subtitle: Text('${stamp(file.modifiedAt.toLocal())} · ${(file.sizeBytes / 1024).toStringAsFixed(1)} KB'),
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

class PinGate extends StatefulWidget {
  final VoidCallback onAuthenticated;
  const PinGate({super.key, required this.onAuthenticated});
  @override State<PinGate> createState() => _PinGateState();
}
class _PinGateState extends State<PinGate> {
  final pin = TextEditingController();
  final confirm = TextEditingController();
  String? error;
  int failedAttempts=0;
  DateTime? lockedUntil;
  Staff get admin => pos.staff.firstWhere((s) => s.name == 'Admin', orElse: () => pos.staff.first);
  bool get setupRequired => admin.verifyPin('1234');
  @override void dispose() { pin.dispose(); confirm.dispose(); super.dispose(); }
  void submit() {
    if (lockedUntil != null && DateTime.now().isBefore(lockedUntil!)) { setState(() => error = 'Çok fazla hatalı deneme. 30 saniye bekleyin.'); return; }
    final value = pin.text.trim();
    if (!RegExp(r'^[0-9]{4}$').hasMatch(value) || (setupRequired && value == '1234')) { setState(() => error = '4 rakamlı, varsayılan olmayan bir PIN girin.'); return; }
    if (setupRequired) {
      if (value != confirm.text.trim()) { setState(() => error = 'PIN kodları eşleşmiyor.'); return; }
      failedAttempts=0; admin.setPin(value); pos.currentUser = admin.name; pos.log('Güvenlik', 'Yönetici PIN kodu oluşturuldu'); pos.save(); widget.onAuthenticated(); return;
    }
    if (admin.verifyPin(value)) { failedAttempts=0; pos.currentUser = admin.name; widget.onAuthenticated(); }
    else { failedAttempts++; if(failedAttempts>=5){lockedUntil=DateTime.now().add(const Duration(seconds:30));failedAttempts=0;} setState(() => error = lockedUntil!=null ? 'Çok fazla hatalı deneme. 30 saniye bekleyin.' : 'PIN hatalı.'); pin.clear(); }
  }
  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: ink,
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: Card(
      margin: const EdgeInsets.all(24),
      child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const PosLogo(size: 180),
        const SizedBox(height: 16),
        Text(setupRequired ? 'Yönetici PIN kodunu oluştur' : 'Yönetici girişi', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        TextField(controller: pin, keyboardType: TextInputType.number, obscureText: true, maxLength: 4, decoration: InputDecoration(labelText: setupRequired ? 'Yeni 4 haneli PIN' : 'Yönetici PIN'), onSubmitted: (_) => submit()),
        if (setupRequired) TextField(controller: confirm, keyboardType: TextInputType.number, obscureText: true, maxLength: 4, decoration: const InputDecoration(labelText: 'PIN tekrar')),
        if (error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(error!, style: const TextStyle(color: red))),
        SizedBox(width: double.infinity, child: FilledButton(onPressed: submit, child: Text(setupRequired ? 'PIN oluştur ve devam et' : 'Giriş yap'))),
      ])),
    ))),
  );
}


class RegisterPage extends StatelessWidget {
  const RegisterPage({super.key});

  Future<int?> _amountDialog(BuildContext context, String title,
      {required String label, String initial = '0'}) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext),
            child: const Text('İptal')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, parseMoney(controller.text)),
            child: const Text('Davam et')),
        ],
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
          decoration: const InputDecoration(labelText: 'Qeyd / səbəb')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext),
            child: const Text('İptal')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Yadda saxla')),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _open(BuildContext context) async {
    final amount = await _amountDialog(context, 'Kasayı aç', label: 'Açılış nakdi (₼)');
    if (!context.mounted || amount == null) return;
    final note = await _noteDialog(context, 'Açılış qeydi');
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
    final amount = await _amountDialog(context, 'Kasanı bağla',
      label: 'Faktiki sayılmış nağd (₼)', initial: (expected / 100).toStringAsFixed(2));
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
        appBar: AppBar(title: const Text('Kasa və növbə idarəetməsi')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          Card(child: Padding(padding: const EdgeInsets.all(16),
            child: session == null
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Aktiv kasa növbəsi yoxdur.',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 8),
                  const Text('Yeni növbə açarkən kassadakı başlanğıc nağd məbləği daxil edin.'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: pos.can('register') ? () => _open(context) : null,
                    icon: const Icon(Icons.lock_open), label: const Text('Kasayı aç')),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('KASA AÇIK',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  Text('Açılış: ${stamp(DateTime.parse(session.openedAt).toLocal())}'),
                  const Divider(),
                  _metric('Açılış nakdi', money(session.openingCash)),
                  _metric('Nakit satış', money(pos.cashSalesForSession(session.id))),
                  _metric('Nağd hərəkət', money(pos.cashMovementsForSession(session.id))),
                  _metric('Beklenen nakit', money(pos.expectedRegisterCash(session))),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(onPressed: () => _movement(context, 'Giriş'),
                      icon: const Icon(Icons.add), label: const Text('Pul girişi')),
                    OutlinedButton.icon(onPressed: () => _movement(context, 'Çıxış'),
                      icon: const Icon(Icons.remove), label: const Text('Pul çıxışı')),
                    FilledButton.icon(onPressed: () => _close(context, session),
                      icon: const Icon(Icons.lock), label: const Text('Vardiyayı kapat')),
                  ]),
                ]),
          )),
          const SizedBox(height: 12),
          const Text('Nakit hareketleri',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          if (session == null || !pos.cashMovements.any((m) => m.sessionId == session.id))
            const ListTile(title: Text('Aktiv növbədə nakit hareketi yoxdur.')),
          if (session != null)
            for (final movement in pos.cashMovements.where((m) => m.sessionId == session.id).toList().reversed)
              ListTile(
                leading: Icon(movement.type == 'Giriş' ? Icons.call_received : Icons.call_made),
                title: Text('${movement.type}: ${money(movement.amount)}'),
                subtitle: Text('${movement.note} · ${stamp(DateTime.parse(movement.at).toLocal())}')),
          const Divider(),
          const Text('Önceki vardiyalar',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          if (sessions.isEmpty)
            const ListTile(title: Text('Henüz vardiya kaydı yok.')),
          for (final item in sessions)
            Card(child: ExpansionTile(
              title: Text('${stamp(DateTime.parse(item.openedAt).toLocal())} · ${item.isOpen ? 'Açıq' : 'Bağlı'}'),
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
