import 'package:aqueduct/aqueduct.dart';
import 'package:aqueduct/src/db/managed/relationship_type.dart';
import 'package:sqljocky5/sqljocky.dart';
import 'builders/column.dart' as mysql;
import 'builders/table.dart' as mysql;

class RowInstantiator {
  RowInstantiator(this.rootTableBuilder, this.returningValues);

  final mysql.TableBuilder rootTableBuilder;
  final List<mysql.Returnable> returningValues;

  Map<mysql.TableBuilder, Map<dynamic, ManagedObject>> distinctObjects = {};

  List<U> instancesForRows<U extends ManagedObject>(List<Row> rows) {
    try {
      return rows
          .map((row) => instanceFromRow(row.iterator, returningValues.iterator))
          .where((wrapper) => wrapper.isNew)
          .map((wrapper) => wrapper.instance as U)
          .toList();
    } on ValidationException catch (e) {
      throw StateError("Database error when retrieving value. ${e.toString()}");
    }
  }

  InstanceWrapper instanceFromRow(Iterator<dynamic> rowIterator,
      Iterator<mysql.Returnable> returningIterator,
      {mysql.TableBuilder table}) {
    table ??= rootTableBuilder;

    // Inspect the primary key first.  We are guaranteed to have the primary key come first in any rowIterator.
    rowIterator.moveNext();
    returningIterator.moveNext();

    var primaryKeyValue = rowIterator.current;
    if (primaryKeyValue == null) {
      exhaustNullInstanceIterator(rowIterator, returningIterator);
      return null;
    }

    var alreadyExists = true;
    var instance = getExistingInstance(table, primaryKeyValue);
    if (instance == null) {
      alreadyExists = false;
      instance = createInstanceWithPrimaryKeyValue(table, primaryKeyValue);
    }

    while (returningIterator.moveNext()) {
      var ret = returningIterator.current;
      if (ret is mysql.ColumnBuilder) {
        rowIterator.moveNext();
        applyColumnValueToProperty(instance, ret, rowIterator.current);
      } else if (ret is mysql.TableBuilder) {
        applyRowValuesToInstance(instance, ret, rowIterator);
      }
    }

    return InstanceWrapper(instance, !alreadyExists);
  }

  ManagedObject createInstanceWithPrimaryKeyValue(
      mysql.TableBuilder table, dynamic primaryKeyValue) {
    var instance = table.entity.instanceOf();

    instance[table.entity.primaryKey] = primaryKeyValue;

    var typeMap = distinctObjects[table];
    if (typeMap == null) {
      typeMap = {};
      distinctObjects[table] = typeMap;
    }

    typeMap[instance[instance.entity.primaryKey]] = instance;

    return instance;
  }

  ManagedObject getExistingInstance(
      mysql.TableBuilder table, dynamic primaryKeyValue) {
    var byType = distinctObjects[table];
    if (byType == null) {
      return null;
    }

    return byType[primaryKeyValue];
  }

  void applyRowValuesToInstance(ManagedObject instance,
      mysql.TableBuilder table, Iterator<dynamic> rowIterator) {
    if (table.flattenedColumnsToReturn.isEmpty) {
      return;
    }

    var innerInstanceWrapper =
        instanceFromRow(rowIterator, table.returning.iterator, table: table);

    if (table.joinedBy.relationshipType == ManagedRelationshipType.hasMany) {
      // If to many, put in a managed set.
      final list = (instance[table.joinedBy.name] ??
          table.joinedBy.declaredType
              .newInstance(const Symbol(""), []).reflectee) as ManagedSet;

      if (innerInstanceWrapper != null && innerInstanceWrapper.isNew) {
        list.add(innerInstanceWrapper.instance);
      }
      instance[table.joinedBy.name] = list;
    } else {
      var existingInnerInstance = instance[table.joinedBy.name];

      // If not assigned yet, assign this value (which may be null). If assigned,
      // don't overwrite with a null row that may come after. Once we have it, we have it.

      // Now if it is belongsTo, we may have already populated it with the foreign key object.
      // In this case, we do need to override it
      if (existingInnerInstance == null) {
        instance[table.joinedBy.name] = innerInstanceWrapper?.instance;
      }
    }
  }

  void applyColumnValueToProperty(
      ManagedObject instance, mysql.ColumnBuilder column, dynamic value) {
    var desc = column.property;

    if (desc is ManagedRelationshipDescription) {
      // This is a belongsTo relationship (otherwise it wouldn't be a column), keep the foreign key.
      if (value != null) {
        var innerInstance = desc.destinationEntity.instanceOf();
        innerInstance[desc.destinationEntity.primaryKey] = value;
        instance[desc.name] = innerInstance;
      } else {
        // If null, explicitly add null to map so the value is populated.
        instance[desc.name] = null;
      }
    } else if (desc is ManagedAttributeDescription) {
      
        instance[desc.name] = column.convertValueFromStorage(value);
     
    }
  }

  void exhaustNullInstanceIterator(Iterator<dynamic> rowIterator,
      Iterator<mysql.Returnable> returningIterator) {
    while (returningIterator.moveNext()) {
      var ret = returningIterator.current;
      if (ret is mysql.TableBuilder) {
        var _ = instanceFromRow(rowIterator, ret.returning.iterator);
      } else {
        rowIterator.moveNext();
      }
    }
  }
}

class InstanceWrapper {
  // ignore: avoid_positional_boolean_parameters
  InstanceWrapper(this.instance, this.isNew);

  bool isNew;
  ManagedObject instance;
}
