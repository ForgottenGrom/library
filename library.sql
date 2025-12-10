-- Бібліотечна система - База даних

-- Видалення старих об'єктів для чистого запуску
DROP VIEW IF EXISTS active_loans;
DROP VIEW IF EXISTS available_books;
DROP FUNCTION IF EXISTS search_books(TEXT);
DROP PROCEDURE IF EXISTS issue_book(INT, INT, INT);
DROP TRIGGER IF EXISTS trg_loan_status ON loans;
DROP TRIGGER IF EXISTS trg_fines ON loans;
DROP FUNCTION IF EXISTS update_instance_status();
DROP FUNCTION IF EXISTS create_fine();
DROP TABLE IF EXISTS fines, reservations, loans, readers, book_instances, book_genres, book_authors, books, genres, publishers, authors;
DROP TYPE IF EXISTS book_instance_status, reservation_status;

-- Створення типів
CREATE TYPE book_instance_status AS ENUM ('available', 'on_loan', 'reserved', 'in_repair', 'lost', 'written_off');
CREATE TYPE reservation_status AS ENUM ('active', 'completed', 'canceled');

-- Таблиця авторів
CREATE TABLE authors (
    author_id SERIAL PRIMARY KEY,
    full_name VARCHAR(255) NOT NULL,
    birth_date DATE,
    biography TEXT
);

CREATE INDEX idx_authors_full_name ON authors(full_name);

-- Таблиця видавництв
CREATE TABLE publishers (
    publisher_id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,
    city VARCHAR(100)
);

-- Таблиця жанрів
CREATE TABLE genres (
    genre_id SERIAL PRIMARY KEY,
    name VARCHAR(100) UNIQUE NOT NULL
);

-- Таблиця книг
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    isbn VARCHAR(20) UNIQUE,
    publication_year INT CHECK (publication_year > 1000 AND publication_year <= EXTRACT(YEAR FROM CURRENT_DATE)),
    pages INT CHECK (pages > 0),
    annotation TEXT,
    publisher_id INT REFERENCES publishers(publisher_id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_books_title ON books(title);

-- Зв'язок книги-автори
CREATE TABLE book_authors (
    book_id INT NOT NULL REFERENCES books(book_id) ON DELETE CASCADE,
    author_id INT NOT NULL REFERENCES authors(author_id) ON DELETE CASCADE,
    PRIMARY KEY (book_id, author_id)
);

-- Зв'язок книги-жанри
CREATE TABLE book_genres (
    book_id INT NOT NULL REFERENCES books(book_id) ON DELETE CASCADE,
    genre_id INT NOT NULL REFERENCES genres(genre_id) ON DELETE CASCADE,
    PRIMARY KEY (book_id, genre_id)
);

-- Таблиця примірників книг
CREATE TABLE book_instances (
    instance_id SERIAL PRIMARY KEY,
    book_id INT NOT NULL REFERENCES books(book_id) ON DELETE CASCADE,
    inventory_number VARCHAR(50) UNIQUE NOT NULL,
    status book_instance_status NOT NULL DEFAULT 'available'
);

CREATE INDEX idx_book_instances_status ON book_instances(status);

-- Таблиця читачів
CREATE TABLE readers (
    reader_id SERIAL PRIMARY KEY,
    full_name VARCHAR(255) NOT NULL,
    ticket_number VARCHAR(20) UNIQUE NOT NULL,
    registration_date DATE NOT NULL DEFAULT CURRENT_DATE,
    phone_number VARCHAR(20),
    email VARCHAR(255) UNIQUE,
    address TEXT
);

CREATE INDEX idx_readers_full_name ON readers(full_name);

-- Таблиця видач
CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,
    instance_id INT NOT NULL REFERENCES book_instances(instance_id),
    reader_id INT NOT NULL REFERENCES readers(reader_id),
    loan_date DATE NOT NULL DEFAULT CURRENT_DATE,
    due_date DATE NOT NULL,
    return_date DATE,
    CONSTRAINT chk_due_date CHECK (due_date > loan_date),
    CONSTRAINT chk_return_date CHECK (return_date IS NULL OR return_date >= loan_date)
);

CREATE INDEX idx_loans_return_date_null ON loans(return_date) WHERE return_date IS NULL;

-- Таблиця бронювань
CREATE TABLE reservations (
    reservation_id SERIAL PRIMARY KEY,
    book_id INT NOT NULL REFERENCES books(book_id) ON DELETE CASCADE,
    reader_id INT NOT NULL REFERENCES readers(reader_id) ON DELETE CASCADE,
    reservation_date TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status reservation_status NOT NULL DEFAULT 'active'
);

-- Таблиця штрафів
CREATE TABLE fines (
    fine_id SERIAL PRIMARY KEY,
    loan_id INT UNIQUE NOT NULL REFERENCES loans(loan_id),
    amount NUMERIC(10, 2) NOT NULL CHECK (amount >= 0),
    fine_date DATE NOT NULL DEFAULT CURRENT_DATE,
    payment_date DATE
);

-- Тригер для зміни статусу при видачі/поверненні
CREATE OR REPLACE FUNCTION update_instance_status()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE book_instances 
        SET status = 'on_loan' 
        WHERE instance_id = NEW.instance_id;
    ELSIF TG_OP = 'UPDATE' AND NEW.return_date IS NOT NULL AND OLD.return_date IS NULL THEN
        UPDATE book_instances 
        SET status = 'available' 
        WHERE instance_id = NEW.instance_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loan_status
AFTER INSERT OR UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION update_instance_status();

-- Тригер для створення штрафу
CREATE OR REPLACE FUNCTION create_fine()
RETURNS TRIGGER AS $$
DECLARE
    days_overdue INT;
    fine_amount NUMERIC;
BEGIN
    IF NEW.return_date IS NOT NULL AND OLD.return_date IS NULL THEN
        IF NEW.return_date > NEW.due_date THEN
            days_overdue := NEW.return_date - NEW.due_date;
            fine_amount := days_overdue * 5.00; -- Ставка штрафу
            
            INSERT INTO fines (loan_id, amount, fine_date)
            VALUES (NEW.loan_id, fine_amount, NEW.return_date);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_fines
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION create_fine();

-- VIEW для активних видач
CREATE VIEW active_loans AS
SELECT 
    l.loan_id,
    r.full_name AS reader,
    r.ticket_number,
    b.title,
    l.loan_date,
    l.due_date,
    CASE 
        WHEN CURRENT_DATE > l.due_date THEN CURRENT_DATE - l.due_date
        ELSE 0 
    END AS days_overdue
FROM loans l
JOIN readers r ON l.reader_id = r.reader_id
JOIN book_instances bi ON l.instance_id = bi.instance_id
JOIN books b ON bi.book_id = b.book_id
WHERE l.return_date IS NULL;

-- VIEW для доступних книг
CREATE VIEW available_books AS
SELECT 
    b.book_id,
    b.title,
    STRING_AGG(DISTINCT a.full_name, ', ') AS authors,
    COUNT(bi.instance_id) FILTER (WHERE bi.status = 'available') AS available
FROM books b
LEFT JOIN book_authors ba ON b.book_id = ba.book_id
LEFT JOIN authors a ON ba.author_id = a.author_id
LEFT JOIN book_instances bi ON b.book_id = bi.book_id
GROUP BY b.book_id
HAVING COUNT(bi.instance_id) FILTER (WHERE bi.status = 'available') > 0;

-- Функція пошуку книг
CREATE OR REPLACE FUNCTION search_books(query TEXT)
RETURNS TABLE (
    book_id INT,
    title VARCHAR,
    authors TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        b.book_id,
        b.title,
        STRING_AGG(a.full_name, ', ') AS authors
    FROM books b
    LEFT JOIN book_authors ba ON b.book_id = ba.book_id
    LEFT JOIN authors a ON ba.author_id = a.author_id
    WHERE b.title ILIKE '%' || query || '%' 
       OR a.full_name ILIKE '%' || query || '%'
    GROUP BY b.book_id;
END;
$$ LANGUAGE plpgsql;

-- Процедура видачі книги
CREATE OR REPLACE PROCEDURE issue_book(
    p_instance_id INT,
    p_reader_id INT,
    p_days INT DEFAULT 14
) AS $$
DECLARE
    v_status book_instance_status;
BEGIN
    SELECT status INTO v_status
    FROM book_instances
    WHERE instance_id = p_instance_id;
    
    IF v_status != 'available' THEN
        RAISE EXCEPTION 'Книга недоступна. Статус: %', v_status;
    END IF;
    
    INSERT INTO loans (instance_id, reader_id, due_date)
    VALUES (p_instance_id, p_reader_id, CURRENT_DATE + p_days);
END;
$$ LANGUAGE plpgsql;

-- Тестові дані
INSERT INTO authors (full_name, birth_date) VALUES
('Тарас Шевченко', '1814-03-09'),
('Іван Франко', '1856-08-27'),
('Леся Українка', '1871-02-25');

INSERT INTO publishers (name, city) VALUES
('А-БА-БА-ГА-ЛА-МА-ГА', 'Київ'),
('Видавництво Старого Лева', 'Львів'),
('Фабула', 'Харків');

INSERT INTO genres (name) VALUES
('Поезія'),
('Проза'),
('Драматургія');

INSERT INTO books (title, isbn, publication_year, publisher_id) VALUES
('Кобзар', '9789660374638', 2014, 1),
('Захар Беркут', '9786177535255', 2018, 2);

INSERT INTO book_authors (book_id, author_id) VALUES
(1, 1),
(2, 2);

INSERT INTO book_genres (book_id, genre_id) VALUES
(1, 1),
(2, 2);

INSERT INTO book_instances (book_id, inventory_number) VALUES
(1, 'INV-001'),
(1, 'INV-002'),
(2, 'INV-003');

INSERT INTO readers (full_name, ticket_number, phone_number, email) VALUES
('Медвідь Богдан', 'R-001', '0501234567', 'medvid@email.com'),

('Стародуб Михайло', 'R-002', '0509876543', 'starodub@email.com');
