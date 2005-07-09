module ActiveRecord
  class IrreversibleMigration < ActiveRecordError#:nodoc:
  end
  
  # Migrations can manage the evolution of a schema used by several physical databases. It's a solution
  # to the common problem of adding a field to make a new feature work in your local database, but being unsure of how to
  # push that change to other developers and to the production server. With migrations, you can describe the transformations
  # in self-contained classes that can be checked into version control systems and executed against another database that
  # might be one, two, or five versions behind.
  #
  # Example of a simple migration:
  #
  #   class AddSsl < ActiveRecord::Migration
  #     def self.up
  #       add_column :accounts, :ssl_enabled, :boolean, :default => 1
  #     end
  #   
  #     def self.down
  #       remove_column :accounts, :ssl_enabled
  #     end
  #   end
  #
  # This migration will add a boolean flag to the accounts table and remove it again, if you're backing out of the migration.
  # It shows how all migrations have two class methods +up+ and +down+ that describes the transformations required to implement
  # or remove the migration. These methods can consist of both the migration specific methods, like add_column and remove_column, 
  # but may also contain regular Ruby code for generating data needed for the transformations.
  #
  # Example of a more complex migration that also needs to initialize data:
  #
  #   class AddSystemSettings < ActiveRecord::Migration
  #     def self.up
  #       create_table :system_settings do |t|
  #         t.column :name,     :string
  #         t.column :label,    :string
  #         t.column :value,    :text
  #         t.column :type,     :string
  #         t.column :position, :integer
  #       end
  #   
  #       SystemSetting.create :name => "notice", :label => "Use notice?", :value => 1
  #     end
  #   
  #     def self.down
  #       drop_table :system_settings
  #     end
  #   end
  #
  # This migration first adds the system_settings table, then creates the very first row in it using the Active Record model
  # that relies on the table. It also uses the more advanced create_table syntax where you can specify a complete table schema
  # in one block call.
  #
  # == Available transformations
  #
  # * <tt>create_table(name, options)</tt> Creates a table called +name+ and makes the table object available to a block
  #   that can then add columns to it, following the same format as add_column. See example above. The options hash is for
  #   fragments like "DEFAULT CHARSET=UTF-8" that are appended to the create table definition.
  # * <tt>drop_table(name)</tt>: Drops the table called +name+.
  # * <tt>add_column(table_name, column_name, type, options)</tt>: Adds a new column to the table called +table_name+
  #   named +column_name+ specified to be one of the following types:
  #   :string, :text, :integer, :float, :datetime, :timestamp, :time, :date, :binary, :boolean. A default value can be specified
  #   by passing an +options+ hash like { :default => 11 }.
  # * <tt>rename_column(table_name, column_name, new_column_name)</tt>: Renames a column but keeps the type and content.
  # * <tt>change_column(table_name, column_name, type, options)</tt>:  Changes the column to a different type using the same
  #   parameters as add_column.
  # * <tt>remove_column(table_name, column_name)</tt>: Removes the column named +column_name+ from the table called +table_name+.
  # * <tt>add_index(table_name, column_name)</tt>: Add a new index with the name of the column on the column.
  # * <tt>remove_index(table_name, column_name)</tt>: Remove the index called the same as the column.
  #
  # == Irreversible transformations
  #
  # Some transformations are destructive in a manner that cannot be reversed. Migrations of that kind should raise
  # an <tt>IrreversibleMigration</tt> exception in their +down+ method.
  #
  # == Running migrations from within Rails
  #
  # The Rails package has support for migrations with the <tt>script/generate migration my_new_migration</tt> command and
  # with the <tt>rake migrate</tt> command that'll run all the pending migrations. It'll even create the needed schema_info
  # table automatically if it's missing.
  #
  # == Database support
  #
  # Migrations are currently only supported in MySQL and PostgreSQL.
  #
  # == More examples
  #
  # Not all migrations change the schema. Some just fix the data:
  #
  #   class RemoveEmptyTags < ActiveRecord::Migration
  #     def self.up
  #       Tag.find(:all).each { |tag| tag.destroy if tag.pages.empty? }
  #     end
  #   
  #     def self.down
  #       # not much we can do to restore deleted data
  #     end
  #   end
  #
  # Others remove columns when they migrate up instead of down:
  #
  #   class RemoveUnnecessaryItemAttributes < ActiveRecord::Migration
  #     def self.up
  #       remove_column :items, :incomplete_items_count
  #       remove_column :items, :completed_items_count
  #     end
  #
  #     def self.down
  #       add_column :items, :incomplete_items_count
  #       add_column :items, :completed_items_count
  #     end
  #   end
  #
  # And some times you need to do something in SQL not abstracted directly by migrations:
  #
  #   class MakeJoinUnique < ActiveRecord::Migration
  #     def self.up
  #       execute "ALTER TABLE `pages_linked_pages` ADD UNIQUE `page_id_linked_page_id` (`page_id`,`linked_page_id`)"
  #     end
  #
  #     def self.down
  #       execute "ALTER TABLE `pages_linked_pages` DROP INDEX `page_id_linked_page_id`"
  #     end
  #   end
  class Migration
    class << self
      def up() end
      def down() end

      private
        def method_missing(method, *arguments, &block)
          ActiveRecord::Base.connection.send(method, *arguments, &block)
        end
    end
  end

  class Migrator#:nodoc:
    class << self
      def migrate(migrations_path, target_version = nil)
        case
          when target_version.nil?, current_version < target_version
            up(migrations_path, target_version)
          when current_version > target_version
            down(migrations_path, target_version)
          when current_version == target_version
            return # You're on the right version
        end
      end
      
      def up(migrations_path, target_version = nil)
        self.new(:up, migrations_path, target_version).migrate
      end
      
      def down(migrations_path, target_version = nil)
        self.new(:down, migrations_path, target_version).migrate
      end
      
      def current_version
        Base.connection.select_one("SELECT version FROM schema_info")["version"].to_i
      end
    end
    
    def initialize(direction, migrations_path, target_version = nil)
      raise StandardError.new("This database does not yet support migrations") unless Base.connection.supports_migrations?
      @direction, @migrations_path, @target_version = direction, migrations_path, target_version
      Base.connection.initialize_schema_information
    end

    def current_version
      self.class.current_version
    end

    def migrate
      migration_classes do |version, migration_class|
        Base.logger.info("Reached target version: #{@target_version}") and break if reached_target_version?(version)
        next if irrelevant_migration?(version)

        Base.logger.info "Migrating to #{migration_class} (#{version})"
        migration_class.send(@direction)
        set_schema_version(version)
      end
    end

    private
      def migration_classes
        for migration_file in migration_files
          load(migration_file)
          version, name = migration_version_and_name(migration_file)
          yield version, migration_class(name)
        end
      end
    
      def migration_files
        files = Dir["#{@migrations_path}/[0-9]*_*.rb"].sort
        down? ? files.reverse : files
      end
      
      def migration_class(migration_name)
        migration_name.camelize.constantize
      end
    
      def migration_version_and_name(migration_file)
        return *migration_file.scan(/([0-9]+)_([_a-z0-9]*).rb/).first
      end
      
      def set_schema_version(version)
        Base.connection.update("UPDATE schema_info SET version = #{down? ? version.to_i - 1 : version.to_i}")
      end
      
      def up?
        @direction == :up
      end
      
      def down?
        @direction == :down
      end
      
      def reached_target_version?(version)
        (up? && version.to_i - 1 == @target_version) || (down? && version.to_i == @target_version)
      end
      
      def irrelevant_migration?(version)
        (up? && version.to_i <= current_version) || (down? && version.to_i > current_version)
      end
  end
end
