module Ruql
  class Canvas
    require 'uri'
    require 'faraday'
    #require 'byebug'
    require 'json'
    require 'yaml'
    
    class CanvasApiError < StandardError ; end

    attr_reader :quiz
    attr_reader :default_quiz_options_file
    attr_reader :logger
    attr_reader :dry_run
    attr_reader :output
    
    def initialize(quiz,options={})
      @quiz = quiz
      @logger = quiz.logger
      @gem_root = Gem.loaded_specs['ruql-canvas'].full_gem_path rescue '.'
      @default_quiz_options_file = File.join(@gem_root, 'templates', 'quiz.yml')
      # read YAML options
      yaml_options = options.delete('--canvas-config') || raise(Ruql::OptionsError.new("Canvas config file must be provided"))
      yaml = YAML.load_file(yaml_options)
      logger.warn "Doing dry run without making any changes" if
        (@dry_run = yaml['dry_run'] || options['--canvas-dry-run'])
      @canvas_options = yaml['canvas']
      set_canvas_options(@canvas_options)

      @quiz_options = YAML.load_file(@default_quiz_options_file)['quiz'].merge(yaml['quiz'] || {})
      @quiz_id = @quiz_options['quiz_id'] # may be nil if new quiz is to be created.
      logger.info "Using quiz options:\n#{@quiz_options.inspect}"

      verify_valid_quiz!
      
      @current_group_id = nil
      @response = nil
      @group_count = 0
      @qcount = 0

      @output = ''
      
    end

    def self.allowed_options
      opts = [
        ['--canvas-config', GetoptLong::REQUIRED_ARGUMENT],
        ['--canvas-dry-run', GetoptLong::NO_ARGUMENT],
      ]
      help = <<eos
The Canvas renderer adds the given file as a quiz in Canvas, with these options:
  --canvas-dry-run  - don't actually change anything, but do all non-state-changing API calls.
               You can also set dry_run: true in the YAML file instead.  The presence of either
               mechanism will turn this into a dry run.
  --canvas-config=file.yml - A Yaml file that must contain at least the following:
    dry_run: true   #  don't actually change anything, but check API connection and parsability
    canvas:
      api_base: https://bcourses.berkeley.edu/api/v1 # base URL for Canvas LMS API
      auth_token: 012345    #  Bearer auth token for Canvas API
      course_id: 99999      #  Course ID in Canvas to which a NEW quiz should be added
      # If quiz_id given, replace that quiz's questions and time limit; if not, create new
      quiz_id: 99999
      #  How quiz time limit is set, eg 20-point quiz = 40 minutes. Default is 1
      minutes_per_point: 2  
      # Fixed extra time in addition to minutes/point. Default 5. Total time rounded up to multiple of 5.
      extra_minutes: 5
    quiz:
      # various options that control quiz; defaults are in #{@default_quiz_options_file}
eos
      return [help, opts]
    end

    # We must set up the following before adding questions:
    #  1) create quiz with given options (unless quiz ID is given)
    #  2) for each question in quiz, sorted so that same-pool questions are together:
    #     - if part of a new pool, start new QuizGroup
    #     - add it to the quiz, specifying its group
    # docs: canvas.instructure.com/doc/api/{quizzes,quiz_question_groups,quiz_questions}.html
    
    def verify_valid_quiz!
      unless quiz.questions.all? { |q| MultipleChoice === q || SelectMultiple === q }
        raise Ruql::QuizContentError.new(
          "Canvas renderer currently only supports Multiple Choice and Select All That Apply questions")
      end
    end
    
    def render_quiz
      if @quiz_id
        truncate_quiz!
        @output = "Existing quiz #{@quiz_id}"
      else
        create_quiz!
        @output = "New quiz #{@quiz_id}"
      end
      emit_ungrouped_questions
      emit_grouped_questions
      @output << " now has #{@qcount} questions in #{@group_count} pool(s)"
    end
    #####

    
    private

    # all "ungrouped" questions go into a single big group that can be shuffled.
    # Caveat 1: where groups are typically "pick 1 of the following N", this big group has to be "pick N of the
    #   following N" so that all questions are presented, just in a shuffled order.
    # Caveat 2: all questions in a group must be worth same # points, so we actually have to subdivide
    #   ungrouped questions into subgroups by point value.
    def emit_ungrouped_questions
      ungrouped_question_sets = quiz.ungrouped_questions.group_by(&:points)
      ungrouped_question_sets.each_pair do |points,questions|
        start_new_group(:name => "Group:unpooled:#{points}", :pick_count => questions.length, :question_points => points)
        questions.each do |q|
          canvas_question = render_multiple_choice(q)
          add_question_to_current_group(canvas_question)
        end
      end
    end

    def emit_grouped_questions
      current_group = nil
      quiz.grouped_questions.each do |q|
        if q.question_group != current_group
          start_new_group(:name => "Group:#{q.question_group}", :question_points => q.points)
          current_group = q.question_group
        end
        canvas_question = render_multiple_choice(q)
        add_question_to_current_group(canvas_question)
      end
    end
    
    def set_canvas_options(canvas)
      @course_id = canvas['course_id'] || raise(Ruql::OptionsError.new("course_id missing from config file"))
      @quiz_id = canvas['quiz_id'] # may be nil => create new quiz
      token = canvas['auth_token'] || raise(Ruql::OptionsError.new("auth_token missing from config file"))
      base = canvas['api_base'] || raise(Ruql::OptionsError.new("api_base missing from config file"))
      logger.info "Using #{@base}"
      @canvas = Faraday.new(
        :url => base,
        :headers => {
          'Authorization' => "Bearer #{token}",
          'Content-Type' => 'application/json'
        })
    end

    def canvas(description, method, path, data: nil)
      logger.info "#{method} #{path} #{data}"
      return if dry_run && method.to_s != 'get'
      if data
        response = @canvas.send(method, path, data)
      else
        response = @canvas.send(method, path)
      end
      if response.success?
        return response.body
      else
        raise CanvasApiError.new("#{description}: #{response.status} #{response.body}")
      end
    end
    
    def time_limit_for_quiz
      # intent is 1 point per minute, add 5 minutes for slop, round total up to nearest 5 minutes
      # but # questions is really # unique groups.
      minutes_per_point = (@canvas_options['minutes_per_point'] || 1).to_i
      slop = (@canvas_options['extra_minutes'] || 5).to_i
      limit =  quiz.points.to_i * minutes_per_point + slop
      # round up to 5 minutes
      limit += 5 - (limit % 5)
      logger.info "Time limit #{limit} based on #{quiz.points} points"
      limit
    end
    
    def truncate_quiz!
      # list, then remove, all questions from existing quiz ID
      path = "courses/#{@course_id}/quizzes/#{@quiz_id}"
      response = canvas("Truncating quiz #{@quiz_id}", :get, path + "/questions")
      questions = JSON.parse(response)
      # delete all questions
      questions.each do |q|
        qid = q['id']
        canvas("Delete question #{qid}", :delete, path + "/questions/#{qid}")
      end
      # collect all group numbers, since we have to delete them too
      group_ids = questions.map { |q| q['quiz_group_id'] }.compact.uniq
      group_ids.each do |gid|
        canvas("Delete group #{gid}", :delete, path + "/groups/#{gid}")
      end
      # modify time limit to reflect the questions we're about to replace them with
      # and update quiz title
      update_quiz = {'quiz' => {
          'title' => quiz.title,
          'time_limit' => time_limit_for_quiz
        }}.to_json
      canvas("Update quiz title and time limit", :put, path, data: update_quiz)
    end

    def create_quiz!
      quiz_opts = @quiz_options.merge({
          'title' => quiz.title,
          'time_limit' => time_limit_for_quiz,
        })
      quiz_object = {:quiz => quiz_opts}.to_json
      path = "courses/#{@course_id}/quizzes"
      new_quiz = canvas("Create quiz", :post, path, data: quiz_object)
      @quiz_id = (dry_run ? 'XXXXX' : JSON.parse(new_quiz)['id'])
      logger.info "Created new quiz #{@quiz_id} in course #{@course_id}"
    end

    def start_new_group(options = {})
      options[:question_points] ||= 1
      options[:pick_count] ||= 1
      options[:name] ||= "group:#{@group_count}"
      group = { quiz_groups: [ options ] }
      resp = canvas("Creating new group with #{group.inspect}", :post, "courses/#{@course_id}/quizzes/#{@quiz_id}/groups", data: group.to_json)
      @current_group_id = (dry_run ? 1000+rand(1000) : JSON.parse(resp)['quiz_groups'][0]['id'])
      @group_count += 1
    end

    # Return a Ruby hash representation of a MCQ for Canvas API.  May be modified by caller
    # before converting to JSON.
    def render_multiple_choice(q)
      ans = array_of_answers(q)
      question_text = q.multiple ? '(Select all that apply.) ' + q.question_text : q.question_text
      question_type = q.multiple ? 'multiple_answers_question' : 'multiple_choice_question'
      comments_key = q.raw? ? :incorrect_comments_html : :incorrect_comments_text

      ques = {
        :quiz_group_id => @current_group_id,
        :question_name => "#{q.points} point#{'s' if q.points > 1}",
        :question_type => question_type,
        :points_possible =>  q.points,
        :question_text => question_text,
        :position => 10000,
        :answers => ans
      }
      { question: ques }
    end
    
    def array_of_answers(question)
      question.answers.map do |answer|
        weight = answer.correct? ? 100 : 0
        text_key = question.raw? ? :answer_html : :answer_text
        { text_key => answer.answer_text,
          :answer_weight => weight
        }
      end
    end
    
    def add_question_to_current_group(question)
      question_json = question.to_json
      canvas("Adding to group #{@current_group_id}:\n#{question_json}", :post,
        "courses/#{@course_id}/quizzes/#{@quiz_id}/questions", data: question_json)
      @qcount += 1
    end

  end
end
