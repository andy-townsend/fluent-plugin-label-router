#
# Copyright 2019- Banzai Cloud
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License

require "fluent/plugin/bare_output"
require 'prometheus/client'
require 'concurrent'


module Fluent
  module Plugin
    class LabelRouterOutput < BareOutput
      Fluent::Plugin.register_output("label_router", self)

      helpers :event_emitter, :record_accessor

      #record_accessor_create("log")
      #record_accessor_create("$.key1.key2")
      #record_accessor_create("$['key1'][0]['key2']")
      desc "Emit mode. If `batch`, the plugin will emit events per labels matched."
      config_param :emit_mode, :enum, list: [:record, :batch], default: :batch
      desc "Sticky tags will match only one record from an event stream. The same tag will be treated the same way"
      config_param :sticky_tags, :bool, default: true
      desc "Default label to drain unmatched patterns"
      config_param :default_route, :string, :default => ""
      desc "Metrics labels for the default_route"
      config_param :default_metrics_labels, :hash, :default => {}
      desc "Default tag to drain unmatched patterns"
      config_param :default_tag, :string, :default => ""
      desc "Enable metrics for the router"
      config_param :metrics, :bool, :default => false

      config_section :route, param_name: :routes, multi: true do
        desc "New @LABEL if selectors matched"
        config_param :@label, :string, :default => nil
        desc "New tag if selectors matched"
        config_param :tag, :string, :default => ""
        desc "Extra labels for metrics"
        config_param :metrics_labels, :hash, :default => {}

        config_section :match, param_name: :matches, multi: true do
          desc "Label definition to match record. Example: app:nginx. You can specify more values as comma separated list: key1:value1,key2:value2"
          config_param :labels, :hash, :default => {}
          desc "Field definition to match record. Example: log-target:s3. Matches any field in the log record."
          config_param :fields, :hash, :default => {}
          desc "List of namespace definition to filter the record. Ignored if left empty."
          config_param :namespaces, :array, :default => [], value_type: :string
          desc "List of regex for namespace definition to filter the record. Ignored if left empty."
          config_param :namespaces_regex, :array, :default => [], value_type: :string
          desc "List of namespace labels to filter the record based on where it came from. Ignored if left empty."
          config_param :namespace_labels, :hash, :default => {}
          desc "List of hosts definition to filter the record. Ignored if left empty."
          config_param :hosts, :array, :default => [], value_type: :string
          desc "List of container names definition to filter the record. Ignored if left empty."
          config_param :container_names, :array, :default => [], value_type: :string
          desc "Negate the selection making it an exclude"
          config_param :negate, :bool, :default => false
        end
      end

      class Route
        def initialize(rule, router, registry)
          @router = router
          @matches = rule['matches'] || []
          @tag = rule['tag'].to_s
          @label = rule['@label']
          @metrics_labels = (rule['metrics_labels'].map { |k, v| [k.to_sym, v] }.to_h if rule['metrics_labels'])
          @counter = nil
          unless registry.nil?
              if registry.exist?(:fluentd_router_records_total)
                @counter = registry.get(:fluentd_router_records_total)
              else
                @counter = registry.counter(:fluentd_router_records_total, docstring: "Total number of events routed for the flow", labels: [:flow, :id])
              end
          end
          # Store field paths
          @field_paths = {}
          if @matches && !@matches.empty?
            @matches.each do |match|
              match.fields.each do |field_path, _|
                @field_paths[field_path] = true
              end
            end
          end
        end

        def get_labels
          labels = { 'flow': @label, 'id': "default" }
          !@metrics_labels.nil? ? labels.merge(@metrics_labels) : labels
        end

        # Evaluate selectors
        # We evaluate <match> statements in order:
        # 1. If match == true and negate == false  -> return true
        # 2. If match == true and negate == true   -> return false
        # 3. If match == false and negate == false -> continue
        # 4. If match == false and negate == true  -> continue
        # There is no match at all                 -> return false
        def match?(metadata)
          @matches.each do |match|
            if filter_select(match, metadata)
              return !match.negate
            end
          end
          false
        end

        # Returns true if filter passes (filter match)
        def filter_select(match, metadata)
          # Break on container_name mismatch
          unless match.hosts.empty? || match.hosts.include?(metadata[:host])
            return false
          end
          # Break on host mismatch
          unless match.container_names.empty? || match.container_names.include?(metadata[:container])
            return false
          end
          # Break if list of namespaces is not empty and does not include actual namespace
          unless match.namespaces.empty? || match.namespaces.include?(metadata[:namespace])
            return false
          end
          # Break if list of namespaces is not empty and does not contain any entry that match actual namespace
          unless match.namespaces_regex.empty? || match.namespaces_regex.any? { |pattern| Regexp.new(pattern).match?(metadata[:namespace]) }
            return false
          end
          # Break if list of namespace_labels is not empty and does not match actual namespace labels
          if !match.namespace_labels.empty? && !match_labels(metadata[:namespace_labels], match.namespace_labels)
            return false
          end

          # Check custom fields if any
          if !match.fields.empty?
            match.fields.each do |field_path, expected_value|
              field_value = metadata[:field_values][field_path]
              return false unless field_value.to_s == expected_value.to_s
            end
          end

          match_labels(metadata[:labels], match.labels)
        end

        def emit(tag, time, record)
          if @tag.empty?
            @router.emit(tag, time, record)
          else
            @router.emit(@tag, time, record)
          end
          @counter&.increment(by: 1, labels: get_labels)
        end

        def emit_es(tag, es)
          if @tag.empty?
            @router.emit_stream(tag, es)
          else
            @router.emit_stream(@tag, es)
          end
          # increment the counter for a given label set
          @counter&.increment(by: es.size, labels: get_labels)
        end

        def match_labels(input, match)
          (match.to_a - input.to_a).empty?
        end
      end

      def process(tag, es)
        if @sticky_tags
          @rwlock.with_read_lock {
            if @route_map.has_key?(tag)
              # We already matched with this tag send events to the routers
              @route_map[tag].each do |r|
                r.emit_es(tag, es.dup)
              end
              return
            end
          }
        end
        event_stream = Hash.new {|h, k| h[k] = Fluent::MultiEventStream.new }
        es.each do |time, record|
          # Extract field values for custom field matching
          field_values = {}
          @field_accessors.each do |field_path, accessor|
            begin
              field_values[field_path] = accessor.call(record)
            rescue => e
              log.debug "Failed to access field #{field_path}: #{e}"
              field_values[field_path] = nil
            end
          end

          input_metadata = { labels: @access_to_labels.call(record).to_h,
                             namespace: @access_to_namespace.call(record).to_s,
                             namespace_labels: @access_to_namespace_labels.call(record).to_h,
                             container: @access_to_container_name.call(record).to_s,
                             host: @access_to_host.call(record).to_s,
                             field_values: field_values }
          orphan_record = true
          @routers.each do |r|
            if r.match?(input_metadata)
              orphan_record = false
              if @sticky_tags
                @rwlock.with_write_lock {
                  @route_map[tag].add(r)
                }
              end
              if @batch
                event_stream[r].add(time, record)
              else
                r.emit(tag, time, record.dup)
              end
            end
          end
          if !@default_router.nil? && orphan_record
            if @sticky_tags
              @rwlock.with_write_lock {
                @route_map[tag].add(@default_router)
              }
            end
            if @batch
              event_stream[@default_router].add(time, record)
            else
              @default_router.emit(tag, time, record.dup)
            end
          end
        end
        if @batch
          event_stream.each do |r, es|
            r.emit_es(tag, es.dup)
          end
        end
      end

      def configure(conf)
        super
        @registry = (::Prometheus::Client.registry if @metrics)
        @route_map = Hash.new { |h, k| h[k] = Set.new }
        @rwlock = Concurrent::ReadWriteLock.new
        @routers = []
        @default_router = nil

        # Collect all field paths
        @field_accessors = {}

        @routes.each do |rule|
          route_router = event_emitter_router(rule['@label'])
          router = Route.new(rule, route_router, @registry)
          @routers << router

          # Create accessors for all field paths
          router.instance_variable_get(:@field_paths).keys.each do |field_path|
            @field_accessors[field_path] ||= record_accessor_create(field_path)
          end
        end

        if @default_route != '' or @default_tag != ''
          default_rule = { 'matches' => nil, 'tag' => @default_tag, '@label' => @default_route, 'metrics_labels' => @default_metrics_labels }
          @default_router = Route.new(default_rule, event_emitter_router(@default_route), @registry)
        end

        @access_to_labels = record_accessor_create("$.kubernetes.labels")
        @access_to_namespace_labels = record_accessor_create("$.kubernetes_namespace.labels")
        @access_to_namespace = record_accessor_create("$.kubernetes.namespace_name")
        @access_to_host = record_accessor_create("$.kubernetes.host")
        @access_to_container_name = record_accessor_create("$.kubernetes.container_name")

        @batch = @emit_mode == :batch
      end
    end
  end
end
