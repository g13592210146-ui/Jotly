import GRDB

nonisolated enum JotlyDatabaseSchema {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("memoryOS_v1") { db in
            try db.create(table: "schema_metadata") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }

            try db.create(table: "conversations") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text)
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull().indexed()
            }

            try db.create(table: "raw_events") { table in
                table.column("id", .text).primaryKey()
                table.column("type", .text).notNull().indexed()
                table.column("content", .text).notNull()
                table.column("attachment_paths_json", .blob)
                table.column("conversation_id", .text).references("conversations", onDelete: .setNull)
                table.column("legacy_card_id", .text).indexed()
                table.column("created_at", .double).notNull().indexed()
            }

            try db.create(table: "messages") { table in
                table.column("id", .text).primaryKey()
                table.column("conversation_id", .text).notNull().references("conversations", onDelete: .cascade).indexed()
                table.column("role", .text).notNull().indexed()
                table.column("content", .text).notNull()
                table.column("raw_event_id", .text).references("raw_events", onDelete: .setNull).indexed()
                table.column("agent_run_id", .text).indexed()
                table.column("created_at", .double).notNull().indexed()
            }

            try db.create(table: "agent_runs") { table in
                table.column("id", .text).primaryKey()
                table.column("trigger_message_id", .text).references("messages", onDelete: .setNull).indexed()
                table.column("status", .text).notNull().indexed()
                table.column("need_memory", .boolean).notNull().defaults(to: false)
                table.column("memory_query", .text)
                table.column("tool_plan_json", .blob)
                table.column("error_message", .text)
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull().indexed()
            }

            try db.create(table: "cards") { table in
                table.column("id", .text).primaryKey()
                table.column("type", .text).notNull().indexed()
                table.column("title", .text).notNull()
                table.column("status", .text).notNull().indexed()
                table.column("content_json", .blob).notNull()
                table.column("source_run_id", .text).references("agent_runs", onDelete: .setNull).indexed()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull().indexed()
            }

            try db.create(table: "card_message_links") { table in
                table.column("card_id", .text).notNull().references("cards", onDelete: .cascade)
                table.column("message_id", .text).notNull().references("messages", onDelete: .cascade)
                table.column("relation_type", .text).notNull()
                table.primaryKey(["card_id", "message_id", "relation_type"])
            }

            try db.create(table: "memory_items") { table in
                table.column("id", .text).primaryKey()
                table.column("type", .text).notNull().indexed()
                table.column("content", .text).notNull()
                table.column("structured_data_json", .blob)
                table.column("importance", .double).notNull().defaults(to: 0.5).indexed()
                table.column("confidence", .double).notNull().defaults(to: 1.0)
                table.column("status", .text).notNull().defaults(to: "active").indexed()
                table.column("source_event_id", .text).references("raw_events", onDelete: .setNull).indexed()
                table.column("source_message_id", .text).references("messages", onDelete: .setNull).indexed()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull().indexed()
            }

            try db.create(table: "entities") { table in
                table.column("id", .text).primaryKey()
                table.column("type", .text).notNull().indexed()
                table.column("name", .text).notNull()
                table.column("normalized_name", .text).notNull().indexed()
                table.column("attributes_json", .blob)
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
                table.uniqueKey(["type", "normalized_name"])
            }

            try db.create(table: "entity_relations") { table in
                table.column("id", .text).primaryKey()
                table.column("from_entity_id", .text).notNull().references("entities", onDelete: .cascade).indexed()
                table.column("relation", .text).notNull().indexed()
                table.column("to_entity_id", .text).references("entities", onDelete: .cascade).indexed()
                table.column("value_json", .blob)
                table.column("confidence", .double).notNull().defaults(to: 1.0)
                table.column("source_memory_id", .text).references("memory_items", onDelete: .setNull).indexed()
                table.column("created_at", .double).notNull()
            }

            try db.create(table: "memory_entity_links") { table in
                table.column("memory_item_id", .text).notNull().references("memory_items", onDelete: .cascade)
                table.column("entity_id", .text).notNull().references("entities", onDelete: .cascade)
                table.column("role", .text)
                table.primaryKey(["memory_item_id", "entity_id"])
            }

            try db.create(table: "card_memory_links") { table in
                table.column("card_id", .text).notNull().references("cards", onDelete: .cascade)
                table.column("memory_item_id", .text).notNull().references("memory_items", onDelete: .cascade)
                table.column("relation_type", .text).notNull()
                table.primaryKey(["card_id", "memory_item_id", "relation_type"])
            }

            try db.create(table: "action_logs") { table in
                table.column("id", .text).primaryKey()
                table.column("agent_run_id", .text).references("agent_runs", onDelete: .setNull).indexed()
                table.column("card_id", .text).references("cards", onDelete: .setNull).indexed()
                table.column("tool_name", .text).notNull().indexed()
                table.column("status", .text).notNull().indexed()
                table.column("parameters_json", .blob)
                table.column("result_json", .blob)
                table.column("error_message", .text)
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull().indexed()
            }

            try db.create(table: "memory_embeddings") { table in
                table.column("memory_item_id", .text).primaryKey().references("memory_items", onDelete: .cascade)
                table.column("model", .text).notNull()
                table.column("dimensions", .integer).notNull()
                table.column("vector_blob", .blob).notNull()
                table.column("created_at", .double).notNull()
            }

            try db.create(table: "shortcut_operations") { table in
                table.column("id", .text).primaryKey()
                table.column("mode", .text).notNull().indexed()
                table.column("phase", .text).notNull().indexed()
                table.column("payload_json", .blob).notNull()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull().indexed()
            }

            try db.create(table: "birthday_events") { table in
                table.column("id", .text).primaryKey()
                table.column("card_id", .text).notNull().indexed()
                table.column("payload_json", .blob).notNull()
                table.column("created_at", .double).notNull()
            }

            try db.create(table: "reminder_tasks") { table in
                table.column("id", .text).primaryKey()
                table.column("card_id", .text).notNull().indexed()
                table.column("birthday_event_id", .text).indexed()
                table.column("payload_json", .blob).notNull()
                table.column("created_at", .double).notNull()
            }
        }

        migrator.registerMigration("memoryOS_v2_memory_retrieval") { db in
            // Existing rows are deliberately marked legacy. Only memories created
            // after this migration enter the asynchronous embedding queue.
            try db.alter(table: "memory_items") { table in
                table.add(column: "embedding_status", .text).notNull().defaults(to: "legacy").indexed()
                table.add(column: "embedding_error", .text)
                table.add(column: "embedded_at", .double)
            }

            try db.execute(sql: """
                CREATE VIRTUAL TABLE memory_items_fts USING fts5(
                    memory_item_id UNINDEXED,
                    content,
                    tokenize = 'trigram'
                );

                INSERT INTO memory_items_fts(memory_item_id, content)
                SELECT id, content FROM memory_items WHERE status = 'active';

                CREATE TRIGGER memory_items_fts_insert AFTER INSERT ON memory_items
                WHEN NEW.status = 'active'
                BEGIN
                    INSERT INTO memory_items_fts(memory_item_id, content)
                    VALUES (NEW.id, NEW.content);
                END;

                CREATE TRIGGER memory_items_fts_update AFTER UPDATE OF content, status ON memory_items
                BEGIN
                    DELETE FROM memory_items_fts WHERE memory_item_id = OLD.id;
                    INSERT INTO memory_items_fts(memory_item_id, content)
                    SELECT NEW.id, NEW.content WHERE NEW.status = 'active';
                END;

                CREATE TRIGGER memory_items_fts_delete AFTER DELETE ON memory_items
                BEGIN
                    DELETE FROM memory_items_fts WHERE memory_item_id = OLD.id;
                END;
                """)
        }

        migrator.registerMigration("memoryOS_v3_mvp_assets_subscriptions") { db in
            try db.create(table: "assets") { table in
                table.column("id", .text).primaryKey()
                table.column("source_card_id", .text).notNull().references("cards", onDelete: .cascade).indexed()
                table.column("normalized_name", .text).notNull().indexed()
                table.column("name", .text).notNull()
                table.column("category", .text).notNull().indexed()
                table.column("quantity", .double).notNull().defaults(to: 1)
                table.column("amount", .double)
                table.column("currency", .text)
                table.column("purchased_at", .double)
                table.column("estimated_expiry_at", .double)
                table.column("estimate_note", .text)
                table.column("payload_json", .blob)
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull().indexed()
                table.uniqueKey(["source_card_id", "normalized_name"])
            }

            try db.create(table: "subscriptions") { table in
                table.column("id", .text).primaryKey()
                table.column("source_card_id", .text).notNull().references("cards", onDelete: .cascade).indexed()
                table.column("normalized_service", .text).notNull().indexed()
                table.column("service_name", .text).notNull()
                table.column("plan_name", .text)
                table.column("amount", .double)
                table.column("currency", .text)
                table.column("billing_cycle", .text)
                table.column("next_billing_at", .double)
                table.column("payload_json", .blob)
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull().indexed()
                table.uniqueKey(["source_card_id", "normalized_service"])
            }
        }

        migrator.registerMigration("memoryOS_v4_card_debug_history") { db in
            try db.create(table: "agent_debug_turns") { table in
                table.column("id", .text).primaryKey()
                table.column("card_id", .text).notNull().references("cards", onDelete: .cascade).indexed()
                table.column("payload_json", .blob).notNull()
                table.column("created_at", .double).notNull().indexed()
                table.column("updated_at", .double).notNull().indexed()
            }
        }

        return migrator
    }
}
