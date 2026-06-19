class AddQuizMode < ActiveRecord::Migration[8.1]
  def change
    # A Verto is a quiz when this is true: its question cards may carry a
    # `correct` key in the cards JSON, and players are scored + shown how they
    # did. Quiz Vertos can still mix in normal (ungraded) measurement questions.
    add_column :surveys, :quiz, :boolean, default: false, null: false

    # Server-computed quiz score cached on the response: `score` correct out of
    # `quiz_max` graded questions. Both nil on non-quiz responses. Cached (rather
    # than recomputed) so the "how you compare" distribution is a cheap read.
    add_column :responses, :score, :integer
    add_column :responses, :quiz_max, :integer
  end
end
