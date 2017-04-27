# Notebook model functionality
module Notebooks
  # Instrumentation and health functions for Notebooks
  module HealthFunctions
    extend ActiveSupport::Concern

    # Class-level health functions
    module ClassMethods
      # Most recently executed notebooks
      def recently_executed
        joins(:executions)
          .select('notebooks.*, MAX(executions.updated_at) AS last_exec')
          .group('notebooks.id')
          .order('last_exec DESC')
      end

      # Most recently executed with failures
      def recently_failed
        joins(:executions)
          .where('executions.success = 0')
          .select('notebooks.*, MAX(executions.updated_at) AS last_failure')
          .group('notebooks.id')
          .order('last_failure DESC')
      end
    end

    def runtime_by_cell(days=30)
      executions
        .joins(:code_cell)
        .where('executions.updated_at > ?', days.days.ago)
        .select('AVG(runtime) AS runtime, code_cells.cell_number')
        .group('cell_number')
        .map {|e| [e.cell_number, e.runtime]}
        .to_h
    end

    # Executions from the last N days
    def latest_executions(days=30)
      if days
        executions.where('executions.updated_at > ?', days.days.ago)
      else
        executions
      end
    end

    # Number of users over last N days
    def unique_users(days=30)
      latest_executions(days).select(:user_id).distinct.count
    end

    # Health score based on execution logs
    # Returns something in the range [-1, 1]
    def compute_health(days=30)
      num_cells = code_cells.count
      num_executions = latest_executions(days).count
      num_users = unique_users(days)
      return nil if num_executions.zero? || num_cells.zero?

      scale = Execution.health_scale(num_users, num_executions.to_f / num_cells)
      scaled_pass_rate = scale * pass_rate(days)
      scaled_depth = scale * execution_depth(days)

      scaled_pass_rate + scaled_depth - 1.0
    end

    # Overall execution pass rate
    def pass_rate(days=30)
      num_executions = latest_executions(days).count
      return nil if num_executions.zero?
      num_success = latest_executions(days).where(success: true).count
      num_success.to_f / num_executions
    end

    def execution_depths(days=30)
      num_cells = code_cells.count
      return {} if num_cells.zero?

      # Group by (user,day) to approximate a "session" of running the notebook
      sessions = executions
        .joins(:code_cell)
        .where('executions.updated_at > ?', days.days.ago)
        .select([
          'user_id',
          'DATE(executions.updated_at) AS day',
          'success',
          'MIN(code_cells.cell_number) AS failure',
          'MAX(code_cells.cell_number) + 1 AS depth'
        ].join(', '))
        .group('user_id, day, success')
        .group_by {|result| [result.user_id, result.day]}

      # Add up exec depth and first failure from all sessions
      depths = 0.0
      failures = 0.0
      sessions.each do |_user_day, values|
        # Convert to {true => max success, false => min failure}
        hash = values.map {|v| [v.success, v.success ? v.depth : v.failure]}.to_h

        # Execution depth = highest-numbered cell successfully executed,
        # divided by number of cells.  Default to 0 if no successess.
        depths += (hash[true] || 0).to_f / num_cells

        # First failure = lowest-numbered cell with failure, divided by
        # number of cells.  Default to 1 if no failures.
        failures += (hash[false] || num_cells).to_f / num_cells
      end

      # Return average across all sessions
      {
        execution_depth: depths.to_f / sessions.count,
        first_failure_depth: failures.to_f / sessions.count
      }
    end

    # On average, where do users encounter their first failure?
    def first_failure_depth(days=30)
      execution_depths(days)[:first_failure_depth]
    end

    # On average, how far into the notebooks do users get?
    def execution_depth(days=30)
      execution_depths(days)[:execution_depth]
    end

    # Number of unhealthy cells
    def unhealthy_cells(days=30)
      code_cells.select {|cell| cell.health_status(days)[:status] == :unhealthy}.count
    end

    # Cell counts etc
    def cell_metrics(days=30)
      status = {
        total_cells: 0,
        unhealthy_cells: 0,
        healthy_cells: 0,
        unknown_cells: 0
      }

      first_bad_cell = nil
      last_good_cell = 0
      code_cells.each do |cell|
        metrics = cell.health_status(days)
        status[:total_cells] += 1
        if metrics[:status] == :healthy
          status[:healthy_cells] += 1
          last_good_cell = cell.cell_number + 1
        elsif metrics[:status] == :unhealthy
          status[:unhealthy_cells] += 1
          first_bad_cell ||= cell.cell_number
        else
          status[:unknown_cells] += 1
        end
      end

      # First bad / last good, as a fraction of total
      if status[:total_cells].positive?
        status[:first_bad_cell] =
          first_bad_cell ? (first_bad_cell.to_f / status[:total_cells]) : 1.0
        status[:last_good_cell] = last_good_cell.to_f / status[:total_cells]
      end

      status
    end

    # More detailed health status
    def health_status(days=30)
      num_cells = code_cells.count
      return { status: :unknown, description: 'No code cells' } if num_cells.zero?
      num_executions = latest_executions(days).count
      if num_executions.zero?
        return {
          status: :unknown,
          description: "No executions in last #{days} days"
        }
      end

      # Initial values
      status = {
        executions: num_executions,
        users: unique_users(days),
        pass_rate: pass_rate(days),
        first_failure_depth: first_failure_depth(days),
        execution_depth: execution_depth(days),
        score: compute_health(days)
      }

      # Add in cell metrics
      status.merge!(cell_metrics(days))

      # Healthy or not
      status[:status] =
        if status[:score] >= 0.25
          :healthy
        elsif status[:score] <= -0.25
          :unhealthy
        else
          :unknown
        end
      users = "#{status[:users]} #{'user'.pluralize(status[:users])}"
      status[:description] =
        "#{(status[:pass_rate] * 100).truncate}% pass rate (#{users}) in last #{days} days"
      status
    end
  end
end
