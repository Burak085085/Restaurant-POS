import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class SupplierRecord {
  final String id;
  String name, phone, notes;
  bool active;
  SupplierRecord({required this.id, required this.name, this.phone = '', this.notes = '', this.active = true});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'notes': notes, 'active': active};
  factory SupplierRecord.fromJson(Map<String, dynamic> j) => SupplierRecord(
    id: j['id']?.toString() ?? '', name: j['name']?.toString() ?? '',
    phone: j['phone']?.toString() ?? '', notes: j['notes']?.toString() ?? '',
    active: j['active'] != false,
  );
}

class PurchaseRecord {
  final String id, supplierId, supplierName, productId, productName, at;
  final int quantity, unitCost;
  const PurchaseRecord({required this.id, required this.supplierId, required this.supplierName,
    required this.productId, required this.productName, required this.quantity,
    required this.unitCost, required this.at});
  int get total => quantity * unitCost;
  Map<String, dynamic> toJson() => {'id': id, 'supplierId': supplierId, 'supplierName': supplierName,
    'productId': productId, 'productName': productName, 'quantity': quantity,
    'unitCost': unitCost, 'at': at};
  factory PurchaseRecord.fromJson(Map<String, dynamic> j) => PurchaseRecord(
    id: j['id']?.toString() ?? '', supplierId: j['supplierId']?.toString() ?? '',
    supplierName: j['supplierName']?.toString() ?? '', productId: j['productId']?.toString() ?? '',
    productName: j['productName']?.toString() ?? '', quantity: (j['quantity'] as num?)?.toInt() ?? 0,
    unitCost: (j['unitCost'] as num?)?.toInt() ?? 0, at: j['at']?.toString() ?? '');
}

class CustomerRecord {
  final String id;
  String name, phone, notes;
  int visits, totalSpent;
  CustomerRecord({required this.id, required this.name, this.phone = '', this.notes = '',
    this.visits = 0, this.totalSpent = 0});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'notes': notes,
    'visits': visits, 'totalSpent': totalSpent};
  factory CustomerRecord.fromJson(Map<String, dynamic> j) => CustomerRecord(
    id: j['id']?.toString() ?? '', name: j['name']?.toString() ?? '',
    phone: j['phone']?.toString() ?? '', notes: j['notes']?.toString() ?? '',
    visits: (j['visits'] as num?)?.toInt() ?? 0, totalSpent: (j['totalSpent'] as num?)?.toInt() ?? 0);
}

class ReservationRecord {
  final String id, customerName, phone, dateTime, note;
  final int tableId, guests;
  String status;
  ReservationRecord({required this.id, required this.customerName, required this.phone,
    required this.dateTime, required this.tableId, required this.guests, this.note = '',
    this.status = 'Bekliyor'});
  Map<String, dynamic> toJson() => {'id': id, 'customerName': customerName, 'phone': phone,
    'dateTime': dateTime, 'tableId': tableId, 'guests': guests, 'note': note, 'status': status};
  factory ReservationRecord.fromJson(Map<String, dynamic> j) => ReservationRecord(
    id: j['id']?.toString() ?? '', customerName: j['customerName']?.toString() ?? '',
    phone: j['phone']?.toString() ?? '', dateTime: j['dateTime']?.toString() ?? '',
    tableId: (j['tableId'] as num?)?.toInt() ?? 1, guests: (j['guests'] as num?)?.toInt() ?? 1,
    note: j['note']?.toString() ?? '', status: j['status']?.toString() ?? 'Bekliyor');
}

class ReceiptPrinter {
  static Future<bool> printSale(dynamic sale) async {
    try {
      final document = pw.Document();
      document.addPage(pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(12),
        build: (context) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Center(child: pw.Text('RESTORAM', style: const pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold))),
          pw.Center(child: pw.Text('Satis fişi', style: const pw.TextStyle(fontSize: 10))),
          pw.SizedBox(height: 8),
          pw.Text('Tarix: ${sale.date}  ${sale.time}'),
          pw.Text('Masa: ${sale.table}'),
          pw.Text('Personel: ${sale.staff}'),
          pw.Divider(),
          for (final item in sale.items)
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Expanded(child: pw.Text('${item.qty} x ${item.name}', style: const pw.TextStyle(fontSize: 9))),
              pw.Text('${(item.qty * item.price / 100).toStringAsFixed(2)}', style: const pw.TextStyle(fontSize: 9)),
            ]),
          pw.Divider(),
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('YEKUN', style: const pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Text('${(sale.total / 100).toStringAsFixed(2)} AZN', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          ]),
          pw.SizedBox(height: 6),
          for (final payment in sale.payments)
            pw.Text('${payment.method}: ${(payment.amount / 100).toStringAsFixed(2)} AZN', style: const pw.TextStyle(fontSize: 9)),
          pw.SizedBox(height: 14),
          pw.Center(child: pw.Text('Teşekkür edirik!', style: const pw.TextStyle(fontSize: 9))),
        ]),
      ));
      final Uint8List bytes = await document.save();
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'restoram-fis-${sale.date}-${sale.time}');
      return true;
    } catch (_) {
      return false;
    }
  }
}
