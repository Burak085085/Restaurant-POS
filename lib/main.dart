// ignore_for_file: deprecated_member_use, curly_braces_in_flow_control_structures

import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int kTableCount = 20;
const String kStoreKey = 'restaurant_pos_v2';
const Color ink = Color(0xFF1B2733), bg = Color(0xFFEEF1F4), green = Color(0xFF23845B), red = Color(0xFFC7443B), amber = Color(0xFFE39A1C);
String money(int cents) => '${cents ~/ 100},${(cents % 100).toString().padLeft(2, '0')} ₼';
int parseMoney(String s) { final value = double.tryParse(s.replaceAll(',', '.')); if (value == null || !value.isFinite || value <= 0 || value > 10000000) return 0; return (value * 100).round(); }
DateTime azNow() => DateTime.now().toUtc().add(const Duration(hours: 4));
String dayKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String stamp(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class Product {
  String id, category, name; int price, stock, lowAt; bool active;
  Product(this.id,this.category,this.name,this.price,{this.stock=100,this.lowAt=5,this.active=true});
  Map<String,dynamic> toJson()=>{'id':id,'category':category,'name':name,'price':price,'stock':stock,'lowAt':lowAt,'active':active};
  factory Product.fromJson(Map<String,dynamic> j)=>Product(j['id']??'',j['category']??'Genel',j['name']??'',j['price']??0,stock:j['stock']??100,lowAt:j['lowAt']??5,active:j['active']??true);
}
enum KitchenState { queued, preparing, ready, served }
class OrderLine {
  String productId, name;
  int price, qty;
  bool sent;
  KitchenState kitchen;
  OrderLine(this.productId, this.name, this.price, this.qty,
      {this.sent = false, this.kitchen = KitchenState.queued});
  Map<String, dynamic> toJson() => {'productId': productId, 'name': name,
    'price': price, 'qty': qty, 'sent': sent, 'kitchen': kitchen.index};
  factory OrderLine.fromJson(Map<String, dynamic> j) => OrderLine(
    j['productId'] ?? '', j['name'] ?? '', j['price'] ?? 0, j['qty'] ?? 0,
    sent: j['sent'] ?? true,
    kitchen: KitchenState.values[(j['kitchen'] ?? 0).clamp(0, 3).toInt()],
  );
}
class PosTable { int id; List<OrderLine> items=[]; KitchenState kitchen=KitchenState.queued; int discount=0; bool discountPercent=false; String discountReason=''; PosTable(this.id); int get subtotal=>items.fold(0,(s,e)=>s+e.price*e.qty); int get total=> (subtotal-(discountPercent?subtotal*discount~/100:discount)).clamp(0,1<<30).toInt(); Map<String,dynamic> toJson()=>{'id':id,'items':items.map((e)=>e.toJson()).toList(),'kitchen':kitchen.index,'discount':discount,'discountPercent':discountPercent,'discountReason':discountReason}; }
class PaymentPart { String method; int amount; int tendered; PaymentPart(this.method,this.amount,{int? tendered}):tendered=tendered??amount; int get change=>method=='Nakit'?(tendered-amount).clamp(0,1<<30).toInt():0; Map<String,dynamic> toJson()=>{'method':method,'amount':amount,'tendered':tendered}; }
class Sale { String date,time,staff; int table,total,discount; List<OrderLine> items; List<PaymentPart> payments; Sale(this.date,this.time,this.staff,this.table,this.total,this.discount,this.items,this.payments); Map<String,dynamic> toJson()=>{'date':date,'time':time,'staff':staff,'table':table,'total':total,'discount':discount,'items':items.map((e)=>e.toJson()).toList(),'payments':payments.map((e)=>e.toJson()).toList()}; factory Sale.fromJson(Map<String,dynamic> j)=>Sale(j['date']??'',j['time']??'',j['staff']??'Admin',j['table']??0,j['total']??0,j['discount']??0,(j['items'] as List? ?? []).map((e)=>OrderLine.fromJson(Map<String,dynamic>.from(e))).toList(),(j['payments'] as List? ?? []).map((e)=>PaymentPart(e['method']??'Nakit',e['amount']??0,tendered:e['tendered']??e['amount']??0)).toList()); }
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
  List<PosTable> tables=List.generate(kTableCount,(i)=>PosTable(i+1)); List<Sale> sales=[]; List<Staff> staff=[Staff('Admin','Yönetici'),Staff('Garson','Garson'),Staff('Mutfak','Mutfak')]; List<Audit> audit=[]; String currentUser='Admin'; SharedPreferences? prefs; Future<void> _queue=Future.value();
  Future<void> load() async { prefs=await SharedPreferences.getInstance(); final raw=prefs!.getString(kStoreKey); if(raw==null)return; try { final j=jsonDecode(raw) as Map<String,dynamic>; products=(j['products'] as List? ?? []).map((e)=>Product.fromJson(Map<String,dynamic>.from(e))).toList(); tables=List.generate(kTableCount,(i)=>PosTable(i+1)); for(final x in (j['tables'] as List? ?? [])){final m=Map<String,dynamic>.from(x); final id=m['id'] as int; if(id<1||id>kTableCount)continue; final t=tables[id-1]; t.items=(m['items'] as List? ?? []).map((e)=>OrderLine.fromJson(Map<String,dynamic>.from(e))).toList(); t.kitchen=KitchenState.values[(m['kitchen']??0).clamp(0,3).toInt()]; final rawItems=(m['items'] as List? ?? []); for(var lineIndex=0;lineIndex<t.items.length;lineIndex++){final rawLine=Map<String,dynamic>.from(rawItems[lineIndex]);if(!rawLine.containsKey('kitchen'))t.items[lineIndex].kitchen=t.kitchen;} t.discount=m['discount']??0;t.discountPercent=m['discountPercent']??false;t.discountReason=m['discountReason']??'';} sales=(j['sales'] as List? ?? []).map((e)=>Sale.fromJson(Map<String,dynamic>.from(e))).toList(); staff=(j['staff'] as List? ?? []).map((e)=>Staff.fromJson(Map<String,dynamic>.from(e))).toList(); if(staff.isEmpty)staff=[Staff('Admin','Yönetici')]; audit=(j['audit'] as List? ?? []).map((e)=>Audit.fromJson(Map<String,dynamic>.from(e))).toList(); currentUser=j['currentUser']??staff.first.name; } catch (_) { final backupKey='${kStoreKey}_corrupt_${DateTime.now().microsecondsSinceEpoch}'; await prefs!.setString(backupKey, raw); await prefs!.remove(kStoreKey); products=[Product('p1','Dönerler','Tavuk döner',300),Product('p2','Dönerler','Dana döner',500),Product('p3','Dönerler','Dürüm döner',400),Product('p4','Dönerler','Porsiyon döner',700),Product('p5','İçecekler','Kola',200),Product('p6','İçecekler','Fanta',200),Product('p7','İçecekler','Ayran',100),Product('p8','İçecekler','Su',50),Product('p9','Ekstra','Patates',200),Product('p10','Ekstra','Ketçap',50),Product('p11','Ekstra','Mayonez',50)]; tables=List.generate(kTableCount,(i)=>PosTable(i+1)); sales=[]; staff=[Staff('Admin','Yönetici')]; audit=[]; currentUser='Admin'; } }
  Future<void> flush()=>_queue;
  void save(){final snapshot=jsonEncode({'products':products.map((e)=>e.toJson()).toList(),'tables':tables.map((e)=>e.toJson()).toList(),'sales':sales.map((e)=>e.toJson()).toList(),'staff':staff.map((e)=>e.toJson()).toList(),'audit':audit.map((e)=>e.toJson()).toList(),'currentUser':currentUser}); _queue=_queue.catchError((Object _) {}).then((_) async { await prefs?.setString(kStoreKey,snapshot); }).catchError((Object _) {}); notifyListeners();}
  void log(String action,String detail){audit.insert(0,Audit(stamp(azNow()),currentUser,action,detail)); if(audit.length>2000)audit.removeRange(2000,audit.length);}
  bool can(String permission){final current=staff.where((e)=>e.name==currentUser&&e.active); if(current.isEmpty)return false; final role=current.first.role; if(role=='Yönetici')return true; if(role=='Mutfak')return permission=='kitchen'; if(role=='Garson')return ['orders','kitchen'].contains(permission); return false;}
  int get todayTotal=>sales.where((s)=>s.date==dayKey(azNow())).fold(0,(a,s)=>a+s.total); int get todayCount=>sales.where((s)=>s.date==dayKey(azNow())).length;
  int reservedStock(String productId) => tables.fold(0, (sum, table) =>
      sum + table.items.where((line) => line.productId == productId).fold(0, (n, line) => n + line.qty));
  bool add(PosTable t, Product p) {
    if (!can('orders') || !p.active || reservedStock(p.id) >= p.stock) return false;
    final existing = t.items.where((line) => line.productId == p.id && !line.sent);
    if (existing.isNotEmpty) { existing.first.qty++; } else { t.items.add(OrderLine(p.id, p.name, p.price, 1)); }
    log('Sipariş', 'Masa ${t.id}: ${p.name} eklendi'); save(); return true;
  }
  bool qty(PosTable t, int i, int delta) {
    if (!can('orders') || i < 0 || i >= t.items.length) return false;
    final line = t.items[i]; final product = products.where((p) => p.id == line.productId);
    if (delta > 0 && (product.isEmpty || reservedStock(line.productId) >= product.first.stock)) return false;
    if (delta < 0 && line.sent) return false;
    if (delta > 0 && line.sent) { t.items.add(OrderLine(line.productId, line.name, line.price, 1)); }
    else { line.qty += delta; if (line.qty <= 0) t.items.removeAt(i); }
    if (t.items.isEmpty) { t.discount=0; t.discountPercent=false; t.discountReason=''; t.kitchen=KitchenState.queued; }
    else if (t.discountPercent ? t.discount > 99 : t.discount >= t.subtotal) { t.discount=0; t.discountPercent=false; t.discountReason=''; log('İndirim sıfırlandı','Masa ${t.id}: ara toplam değiştiği için indirim kaldırıldı'); }
    log('Sipariş', 'Masa ${t.id}: miktar değişti'); save(); return true;
  }
  bool get hasUnsentItems => items.any((line) => !line.sent);
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
  bool stockChange(Product p, int delta) {
    if (!can('inventory')) return false;
    final next = (p.stock + delta).clamp(0, 1000000).toInt();
    if (next < reservedStock(p.id)) return false;
    p.stock = next; log('Stok', '${p.name}: ${p.stock}'); save(); return true;
  }
  bool checkout(PosTable t, List<PaymentPart> payments) {
    if (!can('orders') || t.items.isEmpty) return false;
    final total = t.total;
    if (payments.isEmpty || payments.fold(0, (sum, part) => sum + part.amount) != total) return false;
    for (final line in t.items) {
      final matches = products.where((product) => product.id == line.productId);
      if (matches.isEmpty || matches.first.stock < line.qty) return false;
    }
    final now = azNow();
    for (final line in t.items) { products.firstWhere((product) => product.id == line.productId).stock -= line.qty; }
    sales.add(Sale(dayKey(now), stamp(now), currentUser, t.id, total, t.subtotal-total,
      t.items.map((e) => OrderLine(e.productId, e.name, e.price, e.qty)).toList(), payments));
    log('Ödeme', 'Masa ${t.id}: ${money(total)}');
    t.items = []; t.discount = 0; t.discountPercent = false; t.discountReason = ''; t.kitchen = KitchenState.queued;
    save(); return true;
  }
  bool setStaffActive(Staff member, bool active) {
    if (!can('staff') || (member.name == currentUser && !active)) return false;
    member.active = active; log('Personel', '${member.name}: ${active ? 'aktif' : 'pasif'}'); save(); return true;
  }
  int get lowStock=>products.where((p)=>p.active&&p.stock<=p.lowAt).length;
}
final pos=Pos();
Future<void> main() async {WidgetsFlutterBinding.ensureInitialized();await pos.load();runApp(const PosApp());}
class PosApp extends StatelessWidget {const PosApp({super.key});@override Widget build(BuildContext context)=>MaterialApp(title:'Restaurant POS',debugShowCheckedModeBanner:false,theme:ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:ink),scaffoldBackgroundColor:bg,appBarTheme:const AppBarTheme(backgroundColor:ink,foregroundColor:Colors.white)),home:const Home());}

class Home extends StatefulWidget {const Home({super.key});@override State<Home> createState()=>_HomeState();}
class _HomeState extends State<Home>{int tab=0;bool authenticated=false;@override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(context,_){if(!authenticated)return PinGate(onAuthenticated:()=>setState(()=>authenticated=true));final pages=[const TablesPage(),const KitchenPage(),const InventoryPage(),const ReportsPage(),const AdminPage()];return Scaffold(body:SafeArea(child:pages[tab]),bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v),destinations:const [NavigationDestination(icon:Icon(Icons.table_restaurant),label:'Masalar'),NavigationDestination(icon:Icon(Icons.soup_kitchen),label:'Mutfak'),NavigationDestination(icon:Icon(Icons.inventory_2),label:'Stok'),NavigationDestination(icon:Icon(Icons.bar_chart),label:'Rapor'),NavigationDestination(icon:Icon(Icons.settings),label:'Yönetim') ]));});}

class TablesPage extends StatelessWidget{const TablesPage({super.key});@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Restaurant POS'),actions:[Padding(padding:const EdgeInsets.all(12),child:Center(child:Text(pos.currentUser))) ]),body:Column(children:[Padding(padding:const EdgeInsets.all(12),child:Wrap(spacing:16,children:[Text('Tarih: ${stamp(azNow())}'),if(pos.can('reports')) Text('Bugünkü ciro: ${money(pos.todayTotal)}',style:const TextStyle(fontWeight:FontWeight.bold)),Text('Düşük stok: ${pos.lowStock}') ])),Expanded(child:LayoutBuilder(builder:(c,b){final cols=(b.maxWidth/155).floor().clamp(2,8).toInt();return GridView.builder(padding:const EdgeInsets.all(12),gridDelegate:SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:cols,mainAxisSpacing:10,crossAxisSpacing:10,childAspectRatio:b.maxWidth < 600 ? 1.0 : 0.85),itemCount:pos.tables.length,itemBuilder:(c,i){final t=pos.tables[i];final color=t.items.isEmpty?green:t.kitchen==KitchenState.ready?green:t.kitchen==KitchenState.preparing?amber:red;return Card(child:InkWell(borderRadius:BorderRadius.circular(12),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>OrderPage(table:t))),child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text('Masa ${t.id}',style:const TextStyle(fontWeight:FontWeight.bold,fontSize:17)),Text(t.items.isEmpty?'Boş':t.kitchen==KitchenState.queued?'Kuyruk':t.kitchen==KitchenState.preparing?'Hazırlanıyor':t.kitchen==KitchenState.ready?'Hazır':'Servis edildi'),Text(money(t.total),style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold)),Container(height:5,color:color)]))));});}))]));}

class OrderPage extends StatefulWidget{final PosTable table;const OrderPage({super.key,required this.table});@override State<OrderPage> createState()=>_OrderPageState();}
class _OrderPageState extends State<OrderPage>{String category='Tümü';PosTable get t=>widget.table;@override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(c,_){final cats=['Tümü',...pos.products.map((p)=>p.category).toSet()];final items=pos.products.where((p)=>p.active&&(category=='Tümü'||p.category==category)).toList();return Scaffold(appBar:AppBar(title:Text('Masa ${t.id}')),body:Column(children:[SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:cats.map((x)=>Padding(padding:const EdgeInsets.all(4),child:ChoiceChip(label:Text(x),selected:category==x,onSelected:(_)=>setState(()=>category=x)))).toList())),Expanded(child:LayoutBuilder(builder:(c,b){final wide=b.maxWidth>700;return wide?Row(children:[Expanded(child:_products(items)),SizedBox(width:420,child:_ticket())]):Column(children:[Expanded(child:_products(items)),SizedBox(height:b.maxHeight*.48,child:_ticket())]);} ))]));});
Widget _products(List<Product> list)=>GridView.builder(padding:const EdgeInsets.all(10),gridDelegate:const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent:170,childAspectRatio:1.45,crossAxisSpacing:8,mainAxisSpacing:8),itemCount:list.length,itemBuilder:(c,i){final p=list[i];return Card(child:InkWell(onTap:p.stock>0&&pos.can('orders')?(){if(!pos.add(t,p)){ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('Yeterli stok yok veya işlem yetkiniz bulunmuyor.')));}}:null,child:Padding(padding:const EdgeInsets.all(10),child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text(p.name,style:const TextStyle(fontWeight:FontWeight.bold)),Text(money(p.price)),Text('Stok: ${p.stock}',style:TextStyle(color:p.stock<=p.lowAt?red:Colors.black54))]))));});
Widget _ticket()=>Container(color:Colors.white,child:Column(children:[Padding(padding:const EdgeInsets.all(12),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('Sipariş',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),Text('Mutfak: ${t.kitchen==KitchenState.queued?'Kuyruk':t.kitchen==KitchenState.preparing?'Hazırlanıyor':t.kitchen==KitchenState.ready?'Hazır':'Servis edildi'}') ])),Expanded(child:ListView.builder(itemCount:t.items.length,itemBuilder:(c,i){final x=t.items[i];return ListTile(title:Text(x.name),subtitle:Text('${money(x.price)} × ${x.qty}'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(onPressed:pos.can('orders')&&!x.sent?()=>pos.qty(t,i,-1):null,icon:const Icon(Icons.remove)),IconButton(onPressed:pos.can('orders')?(){if(!pos.qty(t,i,1)){ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text(x.sent?'Mutfağa gönderilen ürünün miktarı değiştirilemez. Yeni ürün satırı ekleyin.':'Stok yetersiz.')));}}:null,icon:const Icon(Icons.add))]));})),Padding(padding:const EdgeInsets.all(12),child:Column(children:[Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('Ara toplam'),Text(money(t.subtotal))]),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('İndirim'),Text(money(t.subtotal-t.total))]),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('TOPLAM',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),Text(money(t.total),style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold))]),Wrap(spacing:8,children:[OutlinedButton.icon(onPressed:t.items.isEmpty||!pos.can('discount')?null:()=>_discount(context),icon:const Icon(Icons.percent),label:const Text('İndirim')),if(t.discount>0) OutlinedButton(onPressed:()=>pos.clearDiscount(t),child:const Text('İndirimi kaldır')),OutlinedButton(onPressed:!t.items.any((item)=>!item.sent)||!pos.can('orders')?null:()=>pos.sendKitchen(t),child:Text(t.items.any((item)=>!item.sent)?'Mutfağa gönder':'Gönderilecek yeni ürün yok'))]),SizedBox(width:double.infinity,child:FilledButton(onPressed:t.items.isEmpty||!pos.can('orders')?null:()=>_pay(context),child:const Text('Ödeme al')))]))]));
Future<void> _discount(BuildContext context)async{final value=TextEditingController(text:t.discountPercent?t.discount.toString():(t.discount/100).toStringAsFixed(2));final reason=TextEditingController(text:t.discountReason);bool percent=t.discountPercent;final ok=await showDialog<bool>(context:context,builder:(c)=>StatefulBuilder(builder:(c,set)=>AlertDialog(title:const Text('İndirim tanımla'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:value,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'İndirim tutarı / yüzde')),SwitchListTile(title:const Text('Yüzde olarak uygula'),value:percent,onChanged:(v)=>set(()=>percent=v)),TextField(controller:reason,decoration:const InputDecoration(labelText:'İndirim nedeni'))]),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Vazgeç')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Uygula'))])));if(!context.mounted)return;if(ok==true){final n=percent?(int.tryParse(value.text)??0):parseMoney(value.text);if(!pos.setDiscount(t,n,percent,reason.text)){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('İndirim için geçerli bir tutar ve neden girin.')));}}}
Future<void> _pay(BuildContext context) async {
  final parts = <PaymentPart>[];
  var remaining = t.total;
  final amount = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text('Ödeme · ${money(t.total)}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Kalan: ${money(remaining)}'),
          TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Tutar (örn. 12,50)')),
          Wrap(children: ['Nakit', 'Kart'].map((method) => TextButton(
            onPressed: () { final next = _addPart(parts, method, amount, remaining); if (next != null) setDialogState(() => remaining = next); },
            child: Text('$method ekle'),
          )).toList()),
          for (final part in parts)
            Text(part.method == 'Nakit'
              ? 'Nakit: ${money(part.amount)} · Alınan: ${money(part.tendered)} · Para üstü: ${money(part.change)}'
              : 'Kart: ${money(part.amount)}'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('İptal')),
          FilledButton(onPressed: remaining == 0 ? () => Navigator.pop(dialogContext, true) : null,
            child: const Text('Ödemeyi tamamla')),
        ],
      ),
    ),
  );
  amount.dispose();
  if (ok == true) {
    if (pos.checkout(t, parts)) { if (context.mounted) Navigator.pop(context); }
    else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Stok değişti veya ödeme tutarı eşleşmiyor. Sipariş korunmuştur.')));
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
}

class KitchenPage extends StatelessWidget {
  const KitchenPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pos,
      builder: (context, _) {
        final activeTables = pos.tables.where((table) => table.items.any((item) => item.sent && item.kitchen != KitchenState.served)).toList();
        return Scaffold(
          appBar: AppBar(title: const Text('Mutfak sipariş kuyruğu')),
          body: activeTables.isEmpty ? const Center(child: Text('Mutfakta bekleyen sipariş yok.')) : ListView.builder(
            itemCount: activeTables.length,
            itemBuilder: (context, index) {
              final table = activeTables[index];
              return Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Masa ${table.id} · ${table.kitchen==KitchenState.queued?'Kuyruk':table.kitchen==KitchenState.preparing?'Hazırlanıyor':table.kitchen==KitchenState.ready?'Hazır':'Servis edildi'}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                      ...table.items.where((item) => item.sent && item.kitchen != KitchenState.served).map((item) => Text('${item.qty} × ${item.name} · ${item.kitchen == KitchenState.queued ? 'Kuyruk' : item.kitchen == KitchenState.preparing ? 'Hazırlanıyor' : 'Hazır'}')),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final state in KitchenState.values)
                            OutlinedButton(
                              onPressed: pos.can('kitchen')
                                  ? () => pos.setKitchen(table, state)
                                  : null,
                              child: Text(
                                state == KitchenState.queued
                                    ? 'Kuyruk'
                                    : state == KitchenState.preparing
                                        ? 'Hazırlanıyor'
                                        : state == KitchenState.ready
                                            ? 'Hazır'
                                            : 'Servis edildi',
                              ),
                            ),
                        ],
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
                        subtitle: Text('${product.category} · ${money(product.price)} · Kritik seviye: ${product.lowAt}'),
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
            TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Fiyat (₼)')),
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
        stock: (int.tryParse(stock.text) ?? 0).clamp(0, 1000000).toInt(),
        lowAt: (int.tryParse(low.text) ?? 5).clamp(0, 1000000).toInt(),
      ));
    }
  }
}

class ReportsPage extends StatelessWidget{const ReportsPage({super.key});@override Widget build(BuildContext context)=>AnimatedBuilder(animation:pos,builder:(c,_) {final today=dayKey(azNow());final allSales=pos.sales.reversed.toList();final sales=pos.sales.where((s)=>s.date==today).toList();final cash=sales.fold(0,(a,s)=>a+s.payments.where((p)=>p.method=='Nakit').fold(0,(x,p)=>x+p.amount));final card=sales.fold(0,(a,s)=>a+s.payments.where((p)=>p.method=='Kart').fold(0,(x,p)=>x+p.amount));return Scaffold(appBar:AppBar(title:const Text('Günlük rapor ve satış geçmişi')),body:pos.can('reports')?ListView(padding:const EdgeInsets.all(12),children:[Wrap(spacing:8,runSpacing:8,children:[_metric('Ciro',money(sales.fold(0,(a,s)=>a+s.total))),_metric('Satış adedi','${sales.length}'),_metric('Nakit',money(cash)),_metric('Kart',money(card))]),const SizedBox(height:12),const Text('Satış geçmişi',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),for(final s in allSales)Card(child:ExpansionTile(title:Text('${s.time} · Masa ${s.table} · ${money(s.total)}'),subtitle:Text('Personel: ${s.staff} · İndirim: ${money(s.discount)}'),children:[for(final x in s.items)ListTile(dense:true,title:Text('${x.qty} × ${x.name}'),trailing:Text(money(x.qty*x.price))),Padding(padding:const EdgeInsets.all(12),child:Text('Ödeme: ${s.payments.map((p)=>p.method=='Nakit'?'Nakit ${money(p.amount)} (alınan ${money(p.tendered)}, para üstü ${money(p.change)})':'Kart ${money(p.amount)}').join(' + ')}'))]))]):const Center(child:Text('Raporlar için yönetici yetkisi gerekir.')));});}
Widget _metric(String title,String value)=>SizedBox(width:160,child:Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title),Text(value,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:19))]))));

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: pos,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: const Text('Yönetim · Personel · Kayıtlar')),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (pos.can('staff')) OutlinedButton.icon(onPressed: () => _changePin(context), icon: const Icon(Icons.lock_reset), label: const Text('Yönetici PIN kodunu değiştir')),
              ListTile(
                title: const Text('Aktif personel'),
                subtitle: Text(pos.currentUser),
                trailing: DropdownButton<String>(
                  value: pos.staff.any((s) => s.active && s.name == pos.currentUser) ? pos.currentUser : null,
                  items: pos.staff.where((s) => s.active).map((s) => DropdownMenuItem(value: s.name, child: Text(s.name))).toList(),
                  onChanged: (value) async {
                    if (value == null) return;
                    final target = pos.staff.firstWhere((s) => s.name == value);
                    final pin = TextEditingController();
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text('$value giriş'),
                        content: TextField(controller: pin, keyboardType: TextInputType.number, obscureText: true, decoration: const InputDecoration(labelText: 'Personel PIN')),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('İptal')),
                          FilledButton(onPressed: () => Navigator.pop(dialogContext, target.verifyPin(pin.text)), child: const Text('Giriş')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      pos.currentUser = value;
                      pos.log('Oturum', 'Aktif kullanıcı: $value');
                      pos.save();
                    } else if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN hatalı veya giriş iptal edildi.')));
                    }
                  },
                ),
              ),
              if (pos.can('staff'))
                FilledButton.icon(onPressed: () => _staffDialog(context), icon: const Icon(Icons.person_add), label: const Text('Personel ekle')),
              if (pos.can('staff')) const Divider(),
              if (pos.can('staff')) const Text('Personel hesapları', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              if (pos.can('staff'))
                for (final member in pos.staff)
                  ListTile(dense: true, title: Text(member.name), subtitle: Text(member.role),
                    trailing: Switch(value: member.active, onChanged: member.name == pos.currentUser ? null : (value) => pos.setStaffActive(member, value))),
              if (pos.can('staff')) const Text('İşlem geçmişi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              if (pos.can('staff'))
                for (final entry in pos.audit.take(100))
                  ListTile(dense: true, title: Text('${entry.action}: ${entry.detail}'), subtitle: Text('${entry.at} · ${entry.user}')),
              if (!pos.can('staff')) const Text('Personel yönetimi ve işlem kayıtları için yönetici yetkisi gerekir.'),
            ],
          ),
        ),
      );

  Future<void> _changePin(BuildContext context) async {
    final oldPin=TextEditingController();
    final newPin=TextEditingController();
    final confirmPin=TextEditingController();
    final ok=await showDialog<bool>(context:context,builder:(dialogContext)=>AlertDialog(
      title:const Text('Yönetici PIN değiştir'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:oldPin,obscureText:true,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Mevcut PIN')),
        TextField(controller:newPin,obscureText:true,keyboardType:TextInputType.number,maxLength:4,decoration:const InputDecoration(labelText:'Yeni 4 haneli PIN')),
        TextField(controller:confirmPin,obscureText:true,keyboardType:TextInputType.number,maxLength:4,decoration:const InputDecoration(labelText:'Yeni PIN tekrar')),
      ]),
      actions:[TextButton(onPressed:()=>Navigator.pop(dialogContext,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(dialogContext,true),child:const Text('Değiştir'))],
    ));
    if(ok==true){
      final admin=pos.staff.firstWhere((member)=>member.name=='Admin');
      final value=newPin.text.trim();
      final valid=admin.verifyPin(oldPin.text.trim())&&value.length==4&&int.tryParse(value)!=null&&value!='1234'&&value==confirmPin.text.trim();
      if(valid){admin.setPin(value);pos.log('Güvenlik','Yönetici PIN kodu değiştirildi');pos.save();}
      else if(context.mounted){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Mevcut PIN yanlış veya yeni PIN geçersiz.')));}
    }
    oldPin.dispose();newPin.dispose();confirmPin.dispose();
  }

  Future<void> _staffDialog(BuildContext context) async {
    final name = TextEditingController();
    final pin = TextEditingController();
    String role = 'Garson';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Personel ekle'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Ad')),
            TextField(controller: pin, keyboardType: TextInputType.number, obscureText: true, decoration: const InputDecoration(labelText: 'Yeni PIN (4-12 rakam)')),
            DropdownButton<String>(
              value: role,
              items: ['Yönetici', 'Garson', 'Mutfak'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
              onChanged: (value) => setDialogState(() => role = value ?? role),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('İptal')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Ekle')),
          ],
        ),
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty && RegExp(r'^[0-9]{4,12}$').hasMatch(pin.text.trim()) && !pos.staff.any((member) => member.name.toLowerCase() == name.text.trim().toLowerCase())) {
      pos.staff.add(Staff(name.text.trim(), role, pin: pin.text.trim()));
      pos.log('Personel', '${name.text} eklendi ($role)');
      pos.save();
    } else if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Benzersiz personel adı ve 4-12 haneli PIN gerekli.')));
    }
  }
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
        const Icon(Icons.lock_outline, size: 48, color: ink),
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
