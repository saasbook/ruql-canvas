module Ruql
  module Canvas
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
    
    def initialize(quiz,options={})
      @quiz = quiz
      @logger = quiz.logger
      @gem_root = Gem.loaded_specs['ruql'].full_gem_path rescue '.'
      @default_quiz_options_file = File.join(@gem_root, 'templates', 'quiz.yml')
      # read YAML options
      yaml_options = options.delete('--canvas-config') || raise Ruql::OptionsError.new("Canvas config file must be provided")
      yaml = YAML.load_file(yaml_options)
      logger.warn "Doing dry run without making any changes" if
        (@dry_run = yaml['dry_run'])
      set_canvas_options(yaml['canvas'])
      @quiz_options = YAML.load_file(@default_quiz_options_file).merge(yaml['quiz'] || {})
      logger.info "Using quiz options:\n#{@quiz_options.inspect}"

      verify_valid_quiz!
      
      @current_group_id = nil
      @response = nil
      @group_count = 0
      @qcount = 1
    end

    def self.allowed_options
      opts = [
        ['--canvas-config', GetoptLong::REQUIRED_ARGUMENT],
      ]
      help = <<eos
The Canvas renderer adds the given file as a quiz in Canvas, with these options:
  --canvas-config=file.yml - A Yaml file that must contain at least the following:
    dry_run: true   #  don't actually change anything, but check API connection and parsability
    canvas:
      api_base: https://bcourses.berkeley.edu/api/v1 # base URL for Canvas LMS API
      auth_token: 012345    #  Bearer auth token for Canvas API
      course_id: 99999      #  Course ID in Canvas to which a NEW quiz should be added
      # Or, EXISTING Canvas quiz ID whose content will be COMPLETELY REPLACED.
      # You must specify exactly one of course ID or quiz ID.
      quiz_id: 99999 
    quiz:
      # various options that control quiz; defaults are in #{default_quiz_options_file}
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
      unless quiz.questions.all? { |q| q===MultipleChoice || q===SelectMultiple }
        raise Ruql::QuizContentError.new(
          "Canvas renderer currently only supports Multiple Choice and Select All That Apply questions")
      end
    end
    
    def render_quiz
      create_quiz
      quiz.questions.each_with_index do |q,i|
        start_new_group
        canvas_question = render_multiple_choice(q,i)
        add_question_to_current_group(canvas_question)
    end

    #####

    private

    def set_canvas_options(canvas)
      @course_id,@quiz_id = canvas.values_at('course_id','quiz_id')
      if (@course_id && @quiz_id) || (!@course_id && !@quiz_id)
        raise Ruql::OptionsError.new("Must set exactly one of course ID or quiz ID")
      end
      token = canvas['auth_token'] || raise Ruql::OptionsError.new("auth_token missing from config file")
      base = canvas['api_base'] || raise Ruql::OptionsError.new("api_base missing from config file")
      logger.info "Using #{@base}"
      @canvas = Faraday.new(
        :url => base,
        :headers => {
          'Authorization' => "Bearer #{token}",
          'Content-Type' => 'application/json'
        })
    end
    
      
    def time_limit_for_points(points)
      # 1 point per minute, add 5 minutes for slop, round up to 5 minutes
      5 * (points.to_i / 5 + 1)
    end
    
    def create_quiz
      quiz = @quiz_options.merge({
          title: quiz.title,
          time_limit: time_limit_for_points(quiz.points),
          due_at: "2020-08-01T23:00Z",
          unlock_at: "2020-05-21T00:00Z"
        }).to_json
      path = "courses/#{course_id}/quizzes"
      if dry_run
        logger.warn "POST #{path}\n#{quiz}"
      else
        @response = @canvas.post("courses/#{course_id}/quizzes", quiz)
        if @response.success?
          @quiz_id = JSON.parse(@response.body)['id']
          logger.info "Created new quiz #{@quiz_id} in course #{@course_id}"
        else
          raise CanvasApiError.new("#{@response.status} #{@response.body}")
        end
      end
    end

    def start_new_group(options = {question_points: 1, pick_count: 1})
      unless options.has_key?(:name)
        options[:name] = "group:#{@group_count}"
        @group_count += 1
      end
      group = { quiz_groups: [ options ] }
      logger.info "Creating new group with #{group.inspect}"
      if dry_run
        @current_group_id = 1000 + rand(1000)
        logger.info "Pretending new group id is #{@current_group_id}"
      else
        @response = @canvas.post("courses/#{@course_id}/quizzes/#{@quiz_id}/groups", group.to_json)
        unless @response.success?
          raise CanvasApiError.new("Error creating quiz group: #{@response.status} #{@response.body}")
        end
        @current_group_id = JSON.parse(@response.body)['quiz_groups'][0]['id']
      end
    end

    # Return a Ruby hash representation of a MCQ for Canvas API.  May be modified by caller
    # before converting to JSON.
    def render_multiple_choice(q,index)
      ans = array_of_answers(q)
      question_text_key = question.raw? ? :question_text_html : :question_text
      question_type = q.multiple? ? 'multiple_answers_question' : 'multiple_choice_question'
      comments_key = question.raw? ? :incorrect_comments_html : :incorrect_comments_text

      ques = {
        :quiz_group_id => @current_group_id,
        :question_name => "#{q.points} point#{'s' if q.points > 1}",
        :question_type => question_type,
        :points_possible =>  q.points,
        question_text_key => q.question_text,
        comments_key => "Answer explanation <b>with bold</b>",
        :position => 10000,
        :answers => ans
      }
      @qcount += 1
      { question: ques }
    end

    def array_of_answers(question)
      question.answers.map do |answer|
        weight = answer.correct? ? 100 : 0
        text_key = question.raw? ? 'html' : 'answer_text'
        { text_key => answer.answer_text,
          :answer_weight => weight }
      end
    end

    def add_question_to_current_group(question)
      question_json = question.to_json
      logger.info "Adding to group #{@current_group_id}:\n#{data}"
      return if dry_run
      @response = @canvas.post("courses/#{@course_id}/quizzes/#{@quiz_id}/questions", question_json)
      @response.success?
    end

  end
end
