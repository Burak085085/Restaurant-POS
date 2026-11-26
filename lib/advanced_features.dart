import 'dart:typed_data';
import 'package:flutter/services.dart';

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
  final String invoiceNumber;
  const PurchaseRecord({required this.id, required this.supplierId, required this.supplierName,
    required this.productId, required this.productName, required this.quantity,
    required this.unitCost, required this.at, this.invoiceNumber = ''});
  int get total => quantity * unitCost;
  Map<String, dynamic> toJson() => {'id': id, 'supplierId': supplierId, 'supplierName': supplierName,
    'productId': productId, 'productName': productName, 'quantity': quantity,
    'unitCost': unitCost, 'at': at, 'invoiceNumber': invoiceNumber};
  factory PurchaseRecord.fromJson(Map<String, dynamic> j) => PurchaseRecord(
    id: j['id']?.toString() ?? '', supplierId: j['supplierId']?.toString() ?? '',
    supplierName: j['supplierName']?.toString() ?? '', productId: j['productId']?.toString() ?? '',
    productName: j['productName']?.toString() ?? '', quantity: (j['quantity'] as num?)?.toInt() ?? 0,
    unitCost: (j['unitCost'] as num?)?.toInt() ?? 0, at: j['at']?.toString() ?? '',
    invoiceNumber: j['invoiceNumber']?.toString() ?? '');
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
  final String? customerId;
  String status;
  bool visitCounted;
  ReservationRecord({required this.id, required this.customerName, required this.phone,
    required this.dateTime, required this.tableId, required this.guests, this.note = '',
    this.status = 'Bekliyor', this.customerId, this.visitCounted = false});
  Map<String, dynamic> toJson() => {'id': id, 'customerName': customerName, 'phone': phone,
    'dateTime': dateTime, 'tableId': tableId, 'guests': guests, 'note': note, 'status': status,
    'customerId': customerId, 'visitCounted': visitCounted};
  factory ReservationRecord.fromJson(Map<String, dynamic> j) => ReservationRecord(
    id: j['id']?.toString() ?? '', customerName: j['customerName']?.toString() ?? '',
    phone: j['phone']?.toString() ?? '', dateTime: j['dateTime']?.toString() ?? '',
    tableId: (j['tableId'] as num?)?.toInt() ?? 1, guests: (j['guests'] as num?)?.toInt() ?? 1,
    note: j['note']?.toString() ?? '', status: j['status']?.toString() ?? 'Bekliyor',
    customerId: j['customerId']?.toString(), visitCounted: j['visitCounted'] == true);
}

class ReceiptPrinter {
  static String _money(int cents) {
    final absolute = cents.abs();
    final amount = '${absolute ~/ 100},${(absolute % 100).toString().padLeft(2, '0')} ₼';
    return cents < 0 ? '-$amount' : amount;
  }

  /// Builds a self-contained receipt PDF with the bundled font so Turkish and
  /// Azerbaijani characters render even when the POS device is offline.
  static Future<Uint8List> buildSalePdf(dynamic sale) async {
    final fontData = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    final font = pw.Font.ttf(fontData);
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );
    document.addPage(pw.Page(
      pageFormat: PdfPageFormat.roll80,
      margin: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Center(child: pw.Text('RESTORAM',
            style: const pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold))),
          pw.Center(child: pw.Text(sale.isRefund ? 'İade fişi' : 'Satış fişi',
            style: const pw.TextStyle(fontSize: 10))),
          pw.SizedBox(height: 8),
          pw.Text('Tarih: ${sale.date}  ${sale.time}', style: const pw.TextStyle(fontSize: 9)),
          pw.Text('Masa: ${sale.table}', style: const pw.TextStyle(fontSize: 9)),
          pw.Text('Personel: ${sale.staff}', style: const pw.TextStyle(fontSize: 9)),
          pw.Divider(),
          if (sale.items.isEmpty && sale.isRefund)
            pw.Text('İade işlemi: ${sale.reason}', style: const pw.TextStyle(fontSize: 9)),
          for (final item in sale.items)
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(child: pw.Text('${item.qty} × ${item.name}',
                  style: const pw.TextStyle(fontSize: 9))),
                pw.SizedBox(width: 6),
                pw.Text(_money(item.qty * item.price),
                  style: const pw.TextStyle(fontSize: 9)),
              ],
            ),
          if (sale.discount > 0) ...[
            pw.Divider(),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('İndirim', style: const pw.TextStyle(fontSize: 9)),
              pw.Text(_money(sale.discount), style: const pw.TextStyle(fontSize: 9)),
            ]),
          ],
          pw.Divider(),
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text(sale.isRefund ? 'İADE TOPLAMI' : 'TOPLAM',
              style: const pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Text(_money(sale.total),
              style: const pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          ]),
          pw.SizedBox(height: 6),
          for (final payment in sale.payments)
            pw.Text('${payment.method}: ${_money(payment.amount)}',
              style: const pw.TextStyle(fontSize: 9)),
          pw.SizedBox(height: 12),
          pw.Center(child: pw.Text('Teşekkür ederiz!',
            style: const pw.TextStyle(fontSize: 9))),
        ],
      ),
    ));
    return document.save();
  }

  static Future<bool> printSale(dynamic sale) async {
    try {
      final bytes = await buildSalePdf(sale);
      return await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: 'restoram-fis-${sale.date}-${sale.time}',
      );
    } catch (_) {
      return false;
    }
  }
}
