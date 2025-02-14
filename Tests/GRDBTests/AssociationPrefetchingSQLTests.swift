import XCTest
#if GRDBCUSTOMSQLITE
    import GRDBCustomSQLite
#else
    import GRDB
#endif

private struct A: TableRecord { }
private struct B: TableRecord { }
private struct C: TableRecord { }
private struct D: TableRecord { }

class AssociationPrefetchingSQLTests: GRDBTestCase {
    override func setup(_ dbWriter: DatabaseWriter) throws {
        try dbWriter.write { db in
            try db.create(table: "a") { t in
                t.autoIncrementedPrimaryKey("cola1")
                t.column("cola2", .text)
            }
            try db.create(table: "b") { t in
                t.autoIncrementedPrimaryKey("colb1")
                t.column("colb2", .integer).references("a")
                t.column("colb3", .text)
            }
            try db.create(table: "c") { t in
                t.autoIncrementedPrimaryKey("colc1")
                t.column("colc2", .integer).references("a")
            }
            try db.create(table: "d") { t in
                t.autoIncrementedPrimaryKey("cold1")
                t.column("cold2", .integer).references("c")
                t.column("cold3", .text)
            }
            try db.execute(
                sql: """
                    INSERT INTO a (cola1, cola2) VALUES (?, ?);
                    INSERT INTO a (cola1, cola2) VALUES (?, ?);
                    INSERT INTO a (cola1, cola2) VALUES (?, ?);
                    INSERT INTO b (colb1, colb2, colb3) VALUES (?, ?, ?);
                    INSERT INTO b (colb1, colb2, colb3) VALUES (?, ?, ?);
                    INSERT INTO b (colb1, colb2, colb3) VALUES (?, ?, ?);
                    INSERT INTO b (colb1, colb2, colb3) VALUES (?, ?, ?);
                    INSERT INTO c (colc1, colc2) VALUES (?, ?);
                    INSERT INTO c (colc1, colc2) VALUES (?, ?);
                    INSERT INTO c (colc1, colc2) VALUES (?, ?);
                    INSERT INTO d (cold1, cold2, cold3) VALUES (?, ?, ?);
                    INSERT INTO d (cold1, cold2, cold3) VALUES (?, ?, ?);
                    INSERT INTO d (cold1, cold2, cold3) VALUES (?, ?, ?);
                    INSERT INTO d (cold1, cold2, cold3) VALUES (?, ?, ?);
                    """,
                arguments: [
                    1, "a1",
                    2, "a2",
                    3, "a3",
                    4, 1, "b1",
                    5, 1, "b2",
                    6, 2, "b3",
                    14, nil, "b4",
                    7, 1,
                    8, 2,
                    9, 2,
                    10, 7, "d1",
                    11, 8, "d2",
                    12, 8, "d3",
                    13, 9, "d4",
                ])
        }
    }
    
    func testIncludingAllHasMany() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.read { db in
            // Plain request
            do {
                let request = A
                    .including(all: A
                        .hasMany(B.self)
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" ORDER BY "cola1"
                    """,
                    """
                    SELECT *, "colb2" AS "grdb_colb2" \
                    FROM "b" \
                    WHERE "colb2" IN (1, 2, 3) \
                    ORDER BY "colb1"
                    """])
            }
            
            // Request with avoided prefetch
            do {
                let request = A
                    .filter(false)
                    .including(all: A
                        .hasMany(B.self)
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM \"a\" WHERE 0 ORDER BY \"cola1\"
                    """])
            }
            
            // Request with filters
            do {
                let request = A
                    .filter(Column("cola1") != 3)
                    .including(all: A
                        .hasMany(B.self)
                        .filter(Column("colb1") == 4)
                        .orderByPrimaryKey()
                        .forKey("bs1"))
                    .including(all: A
                        .hasMany(B.self)
                        .filter(Column("colb1") != 4)
                        .orderByPrimaryKey()
                        .forKey("bs2"))
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" \
                    WHERE "cola1" <> 3 \
                    ORDER BY "cola1"
                    """,
                    """
                    SELECT *, "colb2" AS "grdb_colb2" \
                    FROM "b" \
                    WHERE ("colb1" = 4) AND ("colb2" IN (1, 2)) \
                    ORDER BY "colb1"
                    """,
                    """
                    SELECT *, "colb2" AS "grdb_colb2" \
                    FROM "b" \
                    WHERE ("colb1" <> 4) AND ("colb2" IN (1, 2)) \
                    ORDER BY "colb1"
                    """])
            }
        }
    }
    
    func testIncludingAllHasManyWithCompoundForeignKey() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "parent") { t in
                t.column("parentA", .text)
                t.column("parentB", .text)
                t.primaryKey(["parentA", "parentB"])
            }
            try db.create(table: "child") { t in
                t.column("parentA", .text)
                t.column("parentB", .text)
                t.column("name", .text)
                t.foreignKey(["parentA", "parentB"], references: "parent")
            }
            try db.execute(sql: """
                INSERT INTO parent (parentA, parentB) VALUES ('foo', 'bar');
                INSERT INTO parent (parentA, parentB) VALUES ('baz', 'qux');
                INSERT INTO child (parentA, parentB, name) VALUES ('foo', 'bar', 'foobar1');
                INSERT INTO child (parentA, parentB, name) VALUES ('foo', 'bar', 'foobar2');
                INSERT INTO child (parentA, parentB, name) VALUES ('baz', 'qux', 'bazqux1');
                """)
            
            struct Parent: TableRecord { }
            struct Child: TableRecord { }
            
            // Plain request
            do {
                let request = Parent
                    .including(all: Parent
                        .hasMany(Child.self))
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "parent" ORDER BY "parentA", "parentB"
                    """,
                    """
                    SELECT *, "parentA" AS "grdb_parentA", "parentB" AS "grdb_parentB" \
                    FROM "child" \
                    WHERE (("parentA" = 'baz') AND ("parentB" = 'qux')) OR (("parentA" = 'foo') AND ("parentB" = 'bar'))
                    """])
            }
            
            // Request with avoided prefetch
            do {
                let request = Parent
                    .filter(false)
                    .including(all: Parent
                        .hasMany(Child.self))
                    .orderByPrimaryKey()

                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "parent" WHERE 0 ORDER BY "parentA", "parentB"
                    """])
            }
            
            // Request with filters
            do {
                let request = Parent
                    .including(all: Parent
                        .hasMany(Child.self)
                        .filter(Column("name") == "foo"))
                    .filter(Column("parentA") == "foo")
                    .orderByPrimaryKey()

                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "parent" WHERE "parentA" = 'foo' ORDER BY "parentA", "parentB"
                    """,
                    """
                    SELECT *, "parentA" AS "grdb_parentA", "parentB" AS "grdb_parentB" \
                    FROM "child" WHERE ("name" = 'foo') AND (("parentA" = 'foo') AND ("parentB" = 'bar'))
                    """])
            }
        }
    }

    func testIncludingAllHasManyIncludingAllHasMany() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.read { db in
            // Plain request
            do {
                let request = A
                    .including(all: A
                        .hasMany(C.self)
                        .including(all: C
                            .hasMany(D.self)
                            .orderByPrimaryKey())
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" ORDER BY "cola1"
                    """,
                    """
                    SELECT *, "colc2" AS "grdb_colc2" \
                    FROM "c" \
                    WHERE "colc2" IN (1, 2, 3) \
                    ORDER BY "colc1"
                    """,
                    """
                    SELECT *, "cold2" AS "grdb_cold2" \
                    FROM "d" \
                    WHERE "cold2" IN (7, 8, 9) \
                    ORDER BY "cold1"
                    """])
            }
            
            // Request with avoided prefetch
            do {
                let request = A
                    .including(all: A
                        .hasMany(C.self)
                        .filter(false)
                        .including(all: C
                            .hasMany(D.self)
                            .orderByPrimaryKey())
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" ORDER BY "cola1"
                    """,
                    """
                    SELECT *, "colc2" AS "grdb_colc2" \
                    FROM "c" \
                    WHERE 0 AND ("colc2" IN (1, 2, 3)) \
                    ORDER BY "colc1"
                    """])
            }
            
            // Request with filters
            do {
                let request = A
                    .filter(Column("cola1") != 3)
                    .including(all: A
                        .hasMany(C.self)
                        .filter(Column("colc1") > 7)
                        .including(all: C
                            .hasMany(D.self)
                            .filter(Column("cold1") == 11)
                            .orderByPrimaryKey()
                            .forKey("ds1"))
                        .including(all: C
                            .hasMany(D.self)
                            .filter(Column("cold1") != 11)
                            .orderByPrimaryKey()
                            .forKey("ds2"))
                        .orderByPrimaryKey()
                        .forKey("cs1"))
                    .including(all: A
                        .hasMany(C.self)
                        .filter(Column("colc1") < 9)
                        .including(all: C
                            .hasMany(D.self)
                            .filter(Column("cold1") == 11)
                            .orderByPrimaryKey()
                            .forKey("ds1"))
                        .including(all: C
                            .hasMany(D.self)
                            .filter(Column("cold1") != 11)
                            .orderByPrimaryKey()
                            .forKey("ds2"))
                        .orderByPrimaryKey()
                        .forKey("cs2"))
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * \
                    FROM "a" \
                    WHERE "cola1" <> 3 \
                    ORDER BY "cola1"
                    """,
                    """
                    SELECT *, "colc2" AS "grdb_colc2" \
                    FROM "c" \
                    WHERE ("colc1" > 7) AND ("colc2" IN (1, 2)) \
                    ORDER BY "colc1"
                    """,
                    """
                    SELECT *, "cold2" AS "grdb_cold2" \
                    FROM "d" \
                    WHERE ("cold1" = 11) AND ("cold2" IN (8, 9)) \
                    ORDER BY "cold1"
                    """,
                    """
                    SELECT *, "cold2" AS "grdb_cold2" \
                    FROM "d" \
                    WHERE ("cold1" <> 11) AND ("cold2" IN (8, 9)) \
                    ORDER BY "cold1"
                    """,
                    """
                    SELECT *, "colc2" AS "grdb_colc2" \
                    FROM "c" \
                    WHERE ("colc1" < 9) AND ("colc2" IN (1, 2)) \
                    ORDER BY "colc1"
                    """,
                    """
                    SELECT *, "cold2" AS "grdb_cold2" \
                    FROM "d" \
                    WHERE ("cold1" = 11) AND ("cold2" IN (7, 8)) \
                    ORDER BY "cold1"
                    """,
                    """
                    SELECT *, "cold2" AS "grdb_cold2" \
                    FROM "d" \
                    WHERE ("cold1" <> 11) AND ("cold2" IN (7, 8)) \
                    ORDER BY "cold1"
                    """])
            }
        }
    }
    
    func testIncludingAllHasManyIncludingRequiredOrOptionalHasMany() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.read { db in
            // Plain request
            do {
                let request = A
                    .including(all: A
                        .hasMany(C.self)
                        .including(required: C
                            .hasMany(D.self)
                            .orderByPrimaryKey())
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" ORDER BY "cola1"
                    """,
                    """
                    SELECT "c".*, "c"."colc2" AS "grdb_colc2", "d".* \
                    FROM "c" \
                    JOIN "d" ON "d"."cold2" = "c"."colc1" \
                    WHERE "c"."colc2" IN (1, 2, 3) \
                    ORDER BY "c"."colc1", "d"."cold1"
                    """])
            }
            
            // Request with avoided prefetch
            do {
                let request = A
                    .including(all: A
                        .hasMany(C.self)
                        .filter(false)
                        .including(required: C
                            .hasMany(D.self)
                            .orderByPrimaryKey())
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" ORDER BY "cola1"
                    """,
                    """
                    SELECT "c".*, "c"."colc2" AS "grdb_colc2", "d".* \
                    FROM "c" \
                    JOIN "d" ON "d"."cold2" = "c"."colc1" \
                    WHERE 0 AND ("c"."colc2" IN (1, 2, 3)) \
                    ORDER BY "c"."colc1", "d"."cold1"
                    """])
            }
            
            // Request with filters
            do {
                let request = A
                    .filter(Column("cola1") != 3)
                    .including(all: A
                        .hasMany(C.self)
                        .filter(Column("colc1") > 7)
                        .including(optional: C
                            .hasMany(D.self)
                            .filter(Column("cold1") == 11)
                            .orderByPrimaryKey()
                            .forKey("d1"))
                        .including(required: C
                            .hasMany(D.self)
                            .filter(Column("cold1") != 11)
                            .orderByPrimaryKey()
                            .forKey("d2"))
                        .orderByPrimaryKey()
                        .forKey("cs1"))
                    .including(all: A
                        .hasMany(C.self)
                        .filter(Column("colc1") < 9)
                        .including(optional: C
                            .hasMany(D.self)
                            .filter(Column("cold1") == 11)
                            .orderByPrimaryKey()
                            .forKey("d1"))
                        .including(required: C
                            .hasMany(D.self)
                            .filter(Column("cold1") != 11)
                            .orderByPrimaryKey()
                            .forKey("d2"))
                        .orderByPrimaryKey()
                        .forKey("cs2"))
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * \
                    FROM "a" \
                    WHERE "cola1" <> 3 \
                    ORDER BY "cola1"
                    """,
                    """
                    SELECT "c".*, "c"."colc2" AS "grdb_colc2", "d1".*, "d2".* \
                    FROM "c" \
                    LEFT JOIN "d" "d1" ON ("d1"."cold2" = "c"."colc1") AND ("d1"."cold1" = 11) \
                    JOIN "d" "d2" ON ("d2"."cold2" = "c"."colc1") AND ("d2"."cold1" <> 11) \
                    WHERE ("c"."colc1" > 7) AND ("c"."colc2" IN (1, 2)) \
                    ORDER BY "c"."colc1", "d1"."cold1", "d2"."cold1"
                    """,
                    """
                    SELECT "c".*, "c"."colc2" AS "grdb_colc2", "d1".*, "d2".* \
                    FROM "c" \
                    LEFT JOIN "d" "d1" ON ("d1"."cold2" = "c"."colc1") AND ("d1"."cold1" = 11) \
                    JOIN "d" "d2" ON ("d2"."cold2" = "c"."colc1") AND ("d2"."cold1" <> 11) \
                    WHERE ("c"."colc1" < 9) AND ("c"."colc2" IN (1, 2)) \
                    ORDER BY "c"."colc1", "d1"."cold1", "d2"."cold1"
                    """])
            }
        }
    }
    
    func testIncludingAllHasManyThroughHasManyUsingHasMany() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.read { db in
            // Plain request
            do {
                let request = A
                    .including(all: A
                        .hasMany(D.self, through: A.hasMany(C.self), using: C.hasMany(D.self))
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" ORDER BY "cola1"
                    """,
                    """
                    SELECT "d".*, "c"."colc2" AS "grdb_colc2" \
                    FROM "d" \
                    JOIN "c" ON ("c"."colc1" = "d"."cold2") AND ("c"."colc2" IN (1, 2, 3)) \
                    ORDER BY "d"."cold1"
                    """])
            }
            
            // Request with filters
            do {
                let request = A
                    .filter(Column("cola1") != 3)
                    .including(all: A
                        .hasMany(D.self, through: A.hasMany(C.self).filter(Column("colc1") == 8).forKey("cs1"), using: C.hasMany(D.self))
                        .orderByPrimaryKey()
                        .forKey("ds1"))
                    .including(all: A
                        .hasMany(D.self, through: A.hasMany(C.self).forKey("cs2"), using: C.hasMany(D.self))
                        .filter(Column("cold1") != 11)
                        .orderByPrimaryKey()
                        .forKey("ds2"))
                    .including(all: A
                        .hasMany(D.self, through: A.hasMany(C.self).forKey("cs2"), using: C.hasMany(D.self))
                        .filter(Column("cold1") == 11)
                        .orderByPrimaryKey()
                        .forKey("ds3"))
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" \
                    WHERE "cola1" <> 3 \
                    ORDER BY "cola1"
                    """,
                    """
                    SELECT "d".*, "c"."colc2" AS "grdb_colc2" \
                    FROM "d" \
                    JOIN "c" ON ("c"."colc1" = "d"."cold2") AND ("c"."colc1" = 8) AND ("c"."colc2" IN (1, 2)) \
                    ORDER BY "d"."cold1"
                    """,
                    """
                    SELECT "d".*, "c"."colc2" AS "grdb_colc2" \
                    FROM "d" \
                    JOIN "c" ON ("c"."colc1" = "d"."cold2") AND ("c"."colc2" IN (1, 2)) \
                    WHERE "d"."cold1" <> 11 \
                    ORDER BY "d"."cold1"
                    """,
                    """
                    SELECT "d".*, "c"."colc2" AS "grdb_colc2" \
                    FROM "d" \
                    JOIN "c" ON ("c"."colc1" = "d"."cold2") AND ("c"."colc2" IN (1, 2)) \
                    WHERE "d"."cold1" = 11 \
                    ORDER BY "d"."cold1"
                    """])
            }
        }
    }
    
    func testIncludingAllHasManyThroughBelongsToUsingHasMany() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            // Plain request
            do {
                let request = B
                    .including(all: B.hasMany(C.self, through: B.belongsTo(A.self), using: A.hasMany(C.self))
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "b" ORDER BY "colb1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola1" IN (1, 2)) \
                    ORDER BY "c"."colc1"
                    """])
            }
            
            // Request with filters
            do {
                // This request is an example of what users are unlikely to
                // want, because of the shared key between the two different
                // pivot associations.
                let request = B
                    .including(all: B
                        .hasMany(
                            C.self,
                            through: B.belongsTo(A.self).filter(Column("cola2") == "a1"),
                            using: A.hasMany(C.self))
                        .orderByPrimaryKey())
                    .including(all: B
                        .hasMany(
                            C.self,
                            through: B.belongsTo(A.self).filter(Column("cola2") != "a1"),
                            using: A.hasMany(C.self))
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "b" ORDER BY "colb1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" \
                    JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola2" = 'a1') AND ("a"."cola2" <> 'a1') AND ("a"."cola1" IN (1, 2)) \
                    ORDER BY "c"."colc1"
                    """])
            }
            
            // Request with filters
            do {
                // Another example of what users are unlikely to want, still
                // because of the shared key between the two different pivot
                // associations, and despite the distinct hasMany keys.
                let request = B
                    .including(all: B
                        .hasMany(
                            C.self,
                            through: B.belongsTo(A.self).filter(Column("cola2") == "a1"),
                            using: A.hasMany(C.self))
                        .forKey("a1")
                        .orderByPrimaryKey())
                    .including(all: B
                        .hasMany(
                            C.self,
                            through: B.belongsTo(A.self).filter(Column("cola2") != "a1"),
                            using: A.hasMany(C.self))
                        .forKey("nota1")
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "b" ORDER BY "colb1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" \
                    JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola2" = 'a1') AND ("a"."cola2" <> 'a1') AND ("a"."cola1" IN (1, 2)) \
                    ORDER BY "c"."colc1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" \
                    JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola2" = 'a1') AND ("a"."cola2" <> 'a1') AND ("a"."cola1" IN (1, 2)) \
                    ORDER BY "c"."colc1"
                    """])
            }

            // Request with filters
            do {
                // This request is a "fixed" version of the previous request,
                // where the two different pivot associations do not share the
                // same key.
                let request = B
                    .including(all: B
                        .hasMany(
                            C.self,
                            through: B.belongsTo(A.self).filter(Column("cola2") == "a1").forKey("a1"),
                            using: A.hasMany(C.self))
                        .orderByPrimaryKey())
                    .including(all: B
                        .hasMany(
                            C.self,
                            through: B.belongsTo(A.self).filter(Column("cola2") != "a1").forKey("nota1"),
                            using: A.hasMany(C.self))
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "b" ORDER BY "colb1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" \
                    JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola2" = 'a1') AND ("a"."cola1" IN (1, 2)) \
                    ORDER BY "c"."colc1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" \
                    JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola2" <> 'a1') AND ("a"."cola1" IN (1, 2)) \
                    ORDER BY "c"."colc1"
                    """])
            }
        }
    }
    
    func testIncludingAllHasManyThroughHasOneUsingHasMany() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            // Plain request
            do {
                let request = A
                    .including(all: A.hasMany(D.self, through: A.hasOne(C.self), using: C.hasMany(D.self))
                        .orderByPrimaryKey())
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" ORDER BY "cola1"
                    """,
                    """
                    SELECT "d".*, "c"."colc2" AS "grdb_colc2" \
                    FROM "d" \
                    JOIN "c" ON ("c"."colc1" = "d"."cold2") AND ("c"."colc2" IN (1, 2, 3)) \
                    ORDER BY "d"."cold1"
                    """])
            }
            
            // Request with filters
            do {
                // This request is an example of what users are unlikely to
                // want, because of the shared key between the two different
                // pivot associations.
                // However, A.hasMany(C.self) does not conflict. Thos is an
                // indirect proof that it feeds an association kt, "as", which
                // is distinc from "a" (A.hasOne(C.self)).
                let request = A
                    .including(all: A
                        .hasMany(
                            D.self,
                            through: A.hasOne(C.self).filter(Column("colc1") == 7),
                            using: C.hasMany(D.self))
                        .orderByPrimaryKey())
                    .including(all: A
                        .hasMany(
                            D.self,
                            through: A.hasOne(C.self).filter(Column("colc1") != 7),
                            using: C.hasMany(D.self))
                        .orderByPrimaryKey())
                    .including(all: A.hasMany(C.self))
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" ORDER BY "cola1"
                    """,
                    """
                    SELECT "d".*, "c"."colc2" AS "grdb_colc2" \
                    FROM "d" \
                    JOIN "c" ON ("c"."colc1" = "d"."cold2") AND ("c"."colc1" = 7) AND ("c"."colc1" <> 7) AND ("c"."colc2" IN (1, 2, 3)) \
                    ORDER BY "d"."cold1"
                    """,
                    """
                    SELECT *, "colc2" AS "grdb_colc2" FROM "c" WHERE "colc2" IN (1, 2, 3)
                    """])
            }
            
            // Request with filters
            do {
                // Another example of what users are unlikely to want, still
                // because of the shared key between the two different pivot
                // associations, and despite the distinct hasMany keys.
                let request = A
                    .including(all: A
                        .hasMany(
                            D.self,
                            through: A.hasOne(C.self).filter(Column("colc1") == 7),
                            using: C.hasMany(D.self))
                        .forKey("c7")
                        .orderByPrimaryKey())
                    .including(all: A
                        .hasMany(
                            D.self,
                            through: A.hasOne(C.self).filter(Column("colc1") != 7),
                            using: C.hasMany(D.self))
                        .forKey("notc7")
                        .orderByPrimaryKey())
                    .including(all: A.hasMany(C.self))
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" ORDER BY "cola1"
                    """,
                    """
                    SELECT "d".*, "c"."colc2" AS "grdb_colc2" \
                    FROM "d" \
                    JOIN "c" ON ("c"."colc1" = "d"."cold2") AND ("c"."colc1" = 7) AND ("c"."colc1" <> 7) AND ("c"."colc2" IN (1, 2, 3)) \
                    ORDER BY "d"."cold1"
                    """,
                    """
                    SELECT "d".*, "c"."colc2" AS "grdb_colc2" \
                    FROM "d" \
                    JOIN "c" ON ("c"."colc1" = "d"."cold2") AND ("c"."colc1" = 7) AND ("c"."colc1" <> 7) AND ("c"."colc2" IN (1, 2, 3)) \
                    ORDER BY "d"."cold1"
                    """,
                    """
                    SELECT *, "colc2" AS "grdb_colc2" FROM "c" WHERE "colc2" IN (1, 2, 3)
                    """])
            }

            // Request with filters
            do {
                // This request is a "fixed" version of the previous request,
                // where the two different pivot associations do not share the
                // same key.
                let request = A
                    .including(all: A
                        .hasMany(
                            D.self,
                            through: A.hasOne(C.self).filter(Column("colc1") == 7).forKey("c7"),
                            using: C.hasMany(D.self))
                        .orderByPrimaryKey())
                    .including(all: A
                        .hasMany(
                            D.self,
                            through: A.hasOne(C.self).filter(Column("colc1") != 7).forKey("notc7"),
                            using: C.hasMany(D.self))
                        .orderByPrimaryKey())
                    .including(all: A.hasMany(C.self))
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT * FROM "a" ORDER BY "cola1"
                    """,
                    """
                    SELECT "d".*, "c"."colc2" AS "grdb_colc2" \
                    FROM "d" \
                    JOIN "c" ON ("c"."colc1" = "d"."cold2") AND ("c"."colc1" = 7) AND ("c"."colc2" IN (1, 2, 3)) \
                    ORDER BY "d"."cold1"
                    """,
                    """
                    SELECT "d".*, "c"."colc2" AS "grdb_colc2" \
                    FROM "d" \
                    JOIN "c" ON ("c"."colc1" = "d"."cold2") AND ("c"."colc1" <> 7) AND ("c"."colc2" IN (1, 2, 3)) \
                    ORDER BY "d"."cold1"
                    """,
                    """
                    SELECT *, "colc2" AS "grdb_colc2" FROM "c" WHERE "colc2" IN (1, 2, 3)
                    """])
            }
        }
    }

    // TODO: make a variant with joining(optional:)
    func testIncludingOptionalBelongsToIncludingAllHasMany() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            // Plain request
            do {
                let request = B
                    .including(optional: B
                        .belongsTo(A.self)
                        .including(all: A
                            .hasMany(C.self)
                            .orderByPrimaryKey())
                    )
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT "b".*, "a".* \
                    FROM "b" \
                    LEFT JOIN "a" ON "a"."cola1" = "b"."colb2" \
                    ORDER BY "b"."colb1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" \
                    JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola1" IN (1, 2)) \
                    ORDER BY "c"."colc1"
                    """])
            }
            
            // Request with filters
            do {
                let request = B
                    .including(optional: B
                        .belongsTo(A.self)
                        .filter(Column("cola2") == "a1")
                        .including(all: A
                            .hasMany(C.self)
                            .filter(Column("colc1") == 9)
                            .orderByPrimaryKey()
                            .forKey("cs1"))
                        .including(all: A
                            .hasMany(C.self)
                            .filter(Column("colc1") != 9)
                            .orderByPrimaryKey()
                            .forKey("cs2"))
                        .forKey("a1"))
                    .including(optional: B
                        .belongsTo(A.self)
                        .filter(Column("cola2") == "a2")
                        .including(all: A
                            .hasMany(C.self)
                            .filter(Column("colc1") == 9)
                            .orderByPrimaryKey()
                            .forKey("cs1"))
                        .including(all: A
                            .hasMany(C.self)
                            .filter(Column("colc1") != 9)
                            .orderByPrimaryKey()
                            .forKey("cs2"))
                        .forKey("a2"))
                    .orderByPrimaryKey()
                
                sqlQueries.removeAll()
                _ = try Row.fetchAll(db, request)
                
                let selectQueries = sqlQueries.filter { $0.contains("SELECT") }
                XCTAssertEqual(selectQueries, [
                    """
                    SELECT "b".*, "a1".*, "a2".* \
                    FROM "b" \
                    LEFT JOIN "a" "a1" ON ("a1"."cola1" = "b"."colb2") AND ("a1"."cola2" = 'a1') \
                    LEFT JOIN "a" "a2" ON ("a2"."cola1" = "b"."colb2") AND ("a2"."cola2" = 'a2') \
                    ORDER BY "b"."colb1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" \
                    JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola2" = 'a1') AND ("a"."cola1" IN (1, 2)) \
                    WHERE "c"."colc1" = 9 \
                    ORDER BY "c"."colc1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" \
                    JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola2" = 'a1') AND ("a"."cola1" IN (1, 2)) \
                    WHERE "c"."colc1" <> 9 \
                    ORDER BY "c"."colc1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" \
                    JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola2" = 'a2') AND ("a"."cola1" IN (1, 2)) \
                    WHERE "c"."colc1" = 9 \
                    ORDER BY "c"."colc1"
                    """,
                    """
                    SELECT "c".*, "a"."cola1" AS "grdb_cola1" \
                    FROM "c" \
                    JOIN "a" ON ("a"."cola1" = "c"."colc2") AND ("a"."cola2" = 'a2') AND ("a"."cola1" IN (1, 2)) \
                    WHERE "c"."colc1" <> 9 \
                    ORDER BY "c"."colc1"
                    """])
            }
        }
    }
}
